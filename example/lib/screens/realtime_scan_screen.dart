import 'dart:async';
import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:document_scan/document_scan.dart';
import 'package:flutter/material.dart';

import 'scan_result_screen.dart';

/// Demonstrates realtime detection over a live camera stream.
///
/// The package never owns the camera — this screen drives the `camera` plugin,
/// converts each [CameraImage] into a [ScanInput.bgraFrame] (iOS) or
/// [ScanInput.yuvFrame] (Android), and feeds those frames through
/// [DocumentDetector.detectStream] (with a [CornerStabilizer] to
/// smooth the overlay). Each frame yields a [DetectionEvent] we switch on:
/// [DetectionSuccess] draws the quad, [DetectionEmpty] shows a hint, [DetectionSkipped]
/// is ignored (normal backpressure), [DetectionError] shows a small error.
///
/// Alongside, each frame's corners are fed to an [AutoCaptureAnalyzer] whose
/// [AutoCaptureStatus] drives a status chip (searching → detecting → ready); on
/// `ready` we flash a "Captured!" banner (a real app would grab a still here).
///
/// OVERLAY ALIGNMENT CAVEAT: this demo passes `sensorOrientation` as the frame
/// rotation and draws the returned (upright-space) corners straight onto the
/// `CameraPreview`. On many devices the preview is shown in a different
/// orientation than that upright detection space, so the overlay quad can sit
/// rotated/offset relative to the live image. Getting it pixel-perfect needs
/// the device's current rotation folded into both the frame rotation and a
/// preview transform — that's camera-plumbing, not package logic, and is
/// deliberately left out to keep this example small. The detection, smoothing,
/// event handling and auto-capture are all real; only the overlay-to-preview
/// mapping is simplified. See the ImageFlow app for full orientation handling.
class RealtimeScanScreen extends StatefulWidget {
  const RealtimeScanScreen({super.key});

  @override
  State<RealtimeScanScreen> createState() => _RealtimeScanScreenState();
}

class _RealtimeScanScreenState extends State<RealtimeScanScreen>
    with WidgetsBindingObserver {
  final _detector = DocumentDetector();
  final _scanner = DocumentScanner();
  final _analyzer = AutoCaptureAnalyzer();

  // True from the moment auto-capture fires until we've taken the still and
  // navigated to the result — guards against firing twice and against feeding
  // more frames while the stream is being torn down for the capture.
  bool _capturing = false;

  CameraController? _controller;
  // Frames flow into this controller; detectStream listens on its stream.
  StreamController<ScanInput>? _frames;
  StreamSubscription<DetectionEvent>? _detectionSub;

  // iOS streams accept BGRA only; Android accepts YUV420 (see the README's
  // "Realtime frame format" note). We match the plugin's default per platform.
  late final ScanImageFormat _frameFormat = Platform.isIOS
      ? ScanImageFormat.bgra8888
      : ScanImageFormat.yuv420;

  DocumentCorners? _corners; // smoothed corners for the overlay
  AutoCaptureStatus _capture = AutoCaptureStatus.searching;
  // When on, the screen auto-captures once the document is held steady. When
  // off, detection + the overlay keep running but the user taps the shutter to
  // capture — useful when you want to frame deliberately.
  bool _autoCapture = true;
  String? _error;
  String _hint = 'Starting camera…';
  bool _ready = false;
  // Aspect ratio (width / height) of the frame we actually run detection on,
  // in the UPRIGHT space the overlay is drawn in — captured from the first
  // frame. The preview box uses exactly this so what you see matches what the
  // detector sees, and the overlay lines up pixel-for-pixel.
  double? _detectAspect;
  // Set synchronously at the top of _start() (before any await) so two rapid
  // resume events can't both build a controller and leak the first.
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  Future<void> _start() async {
    // Guard against a double-start (e.g. rapid resume events) leaking a
    // controller. _controller is only assigned after two awaits below, so a
    // second call in that window would slip past a `_controller != null` check
    // and build a second controller; the synchronous `_starting` latch closes
    // that race.
    if (_controller != null || _starting) return;
    _starting = true;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _fail('No camera available on this device.');
        return;
      }
      // Prefer the back camera for documents.
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        // Ask for the format the detector expects on this platform.
        imageFormatGroup: Platform.isIOS
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.yuv420,
      );
      _controller = controller;

      // initialize() triggers the OS permission prompt; a denial throws a
      // CameraException which we surface below rather than crashing.
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }

      await _resumeStream(controller);

      if (!mounted) return;
      setState(() {
        _ready = true;
        _hint = 'Point the camera at a document.';
      });
    } on CameraException catch (e) {
      _fail('Camera unavailable: ${e.description ?? e.code}.');
    } catch (e) {
      _fail('Could not start the camera: $e');
    } finally {
      _starting = false;
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _ready = false;
      _error = message;
      _hint = message;
    });
  }

  // Converts a CameraImage to a ScanInput.bgraFrame / yuvFrame. The plane →
  // ScanInput mapping mirrors the reference realtime pipeline: a single BGRA
  // plane on iOS, three YUV420 planes (+ strides) on Android.
  ScanInput? _toScanInput(CameraImage image, int rotation) {
    if (image.planes.isEmpty) return null;

    if (_frameFormat == ScanImageFormat.bgra8888) {
      final plane = image.planes.first;
      // Format-specific factory: the BGRA plane is a required argument, so a
      // wrong-format call can't compile.
      return ScanInput.bgraFrame(
        width: image.width,
        height: image.height,
        rotation: rotation,
        bytes: plane.bytes,
        bytesPerRow: plane.bytesPerRow,
      );
    }

    // YUV420: three planes.
    if (image.planes.length < 3) return null;
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    return ScanInput.yuvFrame(
      width: image.width,
      height: image.height,
      rotation: rotation,
      yBytes: yPlane.bytes,
      uBytes: uPlane.bytes,
      vBytes: vPlane.bytes,
      yRowStride: yPlane.bytesPerRow,
      uvRowStride: uPlane.bytesPerRow,
      uvPixelStride: uPlane.bytesPerPixel ?? 1,
    );
  }

  void _onEvent(DetectionEvent event) {
    if (!mounted) return;

    // Feed the raw event to the analyzer so it preserves the DetectionSkipped /
    // DetectionError distinction (a dropped frame holds the countdown; a lost
    // document or error resets it) — instead of flattening to corners first.
    // Ignore events once a capture is in flight — the stream is being torn down
    // and we don't want a second frame to re-trigger the analyzer.
    if (_capturing) return;

    final capture = _analyzer.addEvent(event);
    _capture = capture.status;
    if (capture.shouldCapture && _autoCapture) {
      // Auto-capture is on and the document has been held steady long enough:
      // grab a full-resolution still, run the one-call scan on it, and show the
      // result. This is the real end of the realtime flow — not just a flash.
      _capture = AutoCaptureStatus.ready;
      unawaited(_captureStill());
      return;
    }

    // Drive the overlay + hint text off the same event.
    switch (event) {
      case DetectionSuccess(:final corners):
        setState(() {
          _corners = corners;
          _error = null;
          _hint = 'Document detected — hold steady.';
        });
      case DetectionEmpty():
        setState(() {
          _corners = null;
          _error = null;
          _hint = 'Point the camera at a document.';
        });
      case DetectionSkipped():
        break; // normal backpressure under load — ignore
      case DetectionError(:final error):
        setState(() => _error = 'Detection error: $error');
    }
  }

  /// Builds the frame → detectStream pipeline and starts the camera's image
  /// stream. Shared by first start and the post-capture restart so both wire the
  /// throttle + stabilizer identically.
  Future<void> _resumeStream(CameraController controller) async {
    final frames = StreamController<ScanInput>();
    _frames = frames;

    // Feed detected corners through the stabilizer so the overlay doesn't
    // jitter frame-to-frame. Cap detection at ~10/second: the camera pushes
    // frames far faster than that, but running native detection on every one
    // just heats the device without making the overlay look smoother —
    // detectStream drops the frames in between for us.
    _detectionSub = _detector
        .detectStream(
          frames.stream,
          stabilize: CornerStabilizer(),
          minInterval: const Duration(milliseconds: 100),
        )
        .listen(_onEvent);

    // sensorOrientation is the clockwise rotation (degrees) to bring the frame
    // upright. On Android (YUV420) the native side needs it; on iOS the BGRA
    // path is already preview-oriented, so 0 is correct there.
    final rotation = Platform.isIOS ? 0 : controller.description.sensorOrientation;

    await controller.startImageStream((image) {
      // Drop frames while the controller/stream is torn down.
      if (!mounted || frames.isClosed) return;
      // On the first frame, record the detection aspect in upright space so the
      // preview box matches the pixels the detector actually sees. A 90°/270°
      // rotation swaps width/height.
      if (_detectAspect == null) {
        final upright = rotation == 90 || rotation == 270;
        final w = (upright ? image.height : image.width).toDouble();
        final h = (upright ? image.width : image.height).toDouble();
        if (h > 0) setState(() => _detectAspect = w / h);
      }
      final input = _toScanInput(image, rotation);
      if (input != null) frames.add(input);
    });
  }

  /// Auto-capture fired: take a full-resolution still and run the one-call scan
  /// on it, then show the result. A still can't be grabbed while the image
  /// stream is running, so we stop the stream first, capture, scan, and restart
  /// the stream when the user comes back to scan again.
  Future<void> _captureStill() async {
    final controller = _controller;
    if (_capturing || controller == null) return;
    _capturing = true;
    setState(() {
      _corners = null;
      _hint = 'Captured — scanning…';
    });
    try {
      // The image stream and takePicture() can't run at once — stop the stream
      // and tear down the detection pipeline listening on it (but keep the
      // controller alive; we need it for the still). _resumeStream builds a
      // fresh pipeline on restart.
      await _detectionSub?.cancel();
      _detectionSub = null;
      await _frames?.close();
      _frames = null;
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      final photo = await controller.takePicture();
      final scan = await _scanner.scan(ScanInput.file(photo.path));

      if (!mounted) return;
      if (scan == null) {
        // The realtime overlay locked on, but the higher-res still didn't yield
        // a crop — restart scanning rather than dead-ending.
        _hint = 'Could not scan that — try again.';
        await _restartAfterCapture();
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ScanResultScreen(document: scan),
        ),
      );
      // Back from the result — restart the live stream to scan another.
      await _restartAfterCapture();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Capture failed: $e');
      await _restartAfterCapture();
    }
  }

  /// Resets the capture guard + analyzer and brings the live detection stream
  /// back up so the screen is ready for the next document.
  Future<void> _restartAfterCapture() async {
    _analyzer.reset();
    _capturing = false;
    if (!mounted) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    // Rebuild the frame → detectStream pipeline the same way _start does.
    if (!controller.value.isStreamingImages) {
      await _resumeStream(controller);
    }
    if (mounted) {
      setState(() {
        _capture = AutoCaptureStatus.searching;
        _hint = 'Point the camera at a document.';
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Release the camera when backgrounded, restart when resumed. Note: the
    // resume branch must NOT be gated on `_controller != null` — teardown nulls
    // the controller, so gating there would swallow the resume and leave the
    // screen stuck on the "camera off" placeholder forever.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      if (_controller != null) _teardown();
    } else if (state == AppLifecycleState.resumed) {
      _start(); // no-op if already running (guarded inside _start)
    }
  }

  Future<void> _teardown() async {
    final controller = _controller;
    _controller = null;
    await _detectionSub?.cancel();
    _detectionSub = null;
    await _frames?.close();
    _frames = null;
    try {
      if (controller != null && controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {
      // Ignore — controller may already be torn down.
    }
    await controller?.dispose();
    if (mounted) setState(() => _ready = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Fire-and-forget async cleanup — the widget is already gone.
    unawaited(_teardown());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Realtime overlay'),
        actions: [
          // Auto-capture toggle: on = grab automatically once steady, off =
          // wait for the shutter. Kept in the bar so it's reachable while the
          // camera fills the body.
          Row(
            children: [
              const Text('Auto'),
              Switch(
                value: _autoCapture,
                onChanged: _capturing
                    ? null
                    : (v) => setState(() {
                        _autoCapture = v;
                        _analyzer.reset();
                        _capture = AutoCaptureStatus.searching;
                      }),
              ),
            ],
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final controller = _controller;
    if (!_ready || controller == null || !controller.value.isInitialized) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off_outlined, size: 64),
              const SizedBox(height: 16),
              Text(_hint, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    // The overlays sit over a full-bleed camera preview, so we can't use
    // SafeArea (it would inset the preview too). Instead push the bottom banners
    // above the home indicator / nav bar using the device's bottom inset.
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    // Two stacked regions: the camera preview on top (with the status chip and
    // the capture flash over it — the only things that overlap the camera), and
    // a separate text area below it so the hint/caveat never sit on the image.
    return Column(
      children: [
        // Camera area — full width at the DETECTION frame's own aspect ratio, so
        // there are NO black letterbox bands (the box exactly matches the image)
        // and the overlay lines up pixel-for-pixel. Capped to ~62% of the screen
        // height so it stays compact and leaves room for the text area below.
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.62,
          ),
          child: Stack(
            alignment: Alignment.topCenter,
            children: [
              AspectRatio(
                aspectRatio:
                    _detectAspect ?? (1 / controller.value.aspectRatio),
                child: CameraPreview(
                  controller,
                  child: LayoutBuilder(
                    builder: (context, _) => CustomPaint(
                      painter: _DocumentOverlayPainter(_corners),
                      size: Size.infinite,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 12,
                left: 12,
                right: 12,
                child: _CaptureChip(status: _capture),
              ),
            ],
          ),
        ),
        // Text area — below the camera, on the scaffold background, so the
        // hint/caveat are readable and never cover the preview.
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null)
                  _Banner(_error!, color: Colors.red.shade700)
                else
                  _Banner(_hint, color: Colors.black54),
                // Manual shutter — shown only when auto-capture is off. Enabled
                // once a document is detected (the overlay is showing), so a tap
                // grabs the framed document.
                if (!_autoCapture) ...[
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: (_capturing || _corners == null)
                        ? null
                        : () => unawaited(_captureStill()),
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('Capture'),
                  ),
                ],
                const SizedBox(height: 8),
                _Banner(
                  'Demo: overlay-to-preview alignment is simplified — the quad '
                  'may sit rotated on some devices. Detection itself is real.',
                  color: Colors.black45,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Draws the detected document quad + corner dots over the camera preview. The
/// corners are normalized 0..1 over the (upright) preview, so `corner * size`
/// gives local pixels. Ported from the app's realtime overlay painter, made
/// self-contained (inline teal colors, DocumentCorners instead of the app's
/// NormalizedCorners).
class _DocumentOverlayPainter extends CustomPainter {
  _DocumentOverlayPainter(this.corners)
    : _fill = Paint()
        ..color = const Color(0x221DE9B6)
        ..style = PaintingStyle.fill,
      _stroke = Paint()
        ..color = const Color(0xFF1DE9B6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6,
      _corner = Paint()
        ..color = const Color(0xFF1DE9B6)
        ..style = PaintingStyle.fill;

  final DocumentCorners? corners;
  final Paint _fill;
  final Paint _stroke;
  final Paint _corner;

  @override
  void paint(Canvas canvas, Size size) {
    final c = corners;
    if (c == null) return;

    final tl = Offset(c.topLeft.x * size.width, c.topLeft.y * size.height);
    final tr = Offset(c.topRight.x * size.width, c.topRight.y * size.height);
    final br = Offset(
      c.bottomRight.x * size.width,
      c.bottomRight.y * size.height,
    );
    final bl = Offset(
      c.bottomLeft.x * size.width,
      c.bottomLeft.y * size.height,
    );

    final path = Path()
      ..moveTo(tl.dx, tl.dy)
      ..lineTo(tr.dx, tr.dy)
      ..lineTo(br.dx, br.dy)
      ..lineTo(bl.dx, bl.dy)
      ..close();

    canvas.drawPath(path, _fill);
    canvas.drawPath(path, _stroke);

    const radius = 5.0;
    for (final p in [tl, tr, br, bl]) {
      canvas.drawCircle(p, radius, _corner);
    }
  }

  @override
  bool shouldRepaint(covariant _DocumentOverlayPainter old) =>
      old.corners != corners;
}

/// The auto-capture status chip: searching → detecting → ready.
class _CaptureChip extends StatelessWidget {
  const _CaptureChip({required this.status});

  final AutoCaptureStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (status) {
      AutoCaptureStatus.searching => (
        'Searching…',
        Colors.grey.shade700,
        Icons.search,
      ),
      AutoCaptureStatus.detecting => (
        'Detecting…',
        Colors.orange.shade800,
        Icons.center_focus_weak,
      ),
      AutoCaptureStatus.ready => (
        'Ready — hold still',
        Colors.green.shade700,
        Icons.check_circle,
      ),
    };
    return Align(
      alignment: Alignment.centerLeft,
      child: Chip(
        avatar: Icon(icon, size: 18, color: Colors.white),
        label: Text(label, style: const TextStyle(color: Colors.white)),
        backgroundColor: color,
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white, fontSize: 14),
      ),
    );
  }
}
