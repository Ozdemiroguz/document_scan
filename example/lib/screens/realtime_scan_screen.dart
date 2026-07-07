import 'dart:async';
import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:document_scan/document_scan.dart';
import 'package:flutter/material.dart';

/// Demonstrates realtime detection over a live camera stream.
///
/// The package never owns the camera — this screen drives the `camera` plugin,
/// converts each [CameraImage] into a [ScanInput.cameraFrame], and feeds those
/// frames through [DocumentDetector.detectStream] (with a [CornerStabilizer] to
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
  final _analyzer = AutoCaptureAnalyzer();

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
  bool _flashCaptured = false;
  String? _error;
  String _hint = 'Starting camera…';
  bool _ready = false;
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

      final frames = StreamController<ScanInput>();
      _frames = frames;

      // Feed detected corners through the stabilizer so the overlay doesn't
      // jitter frame-to-frame.
      _detectionSub = _detector
          .detectStream(frames.stream, stabilize: CornerStabilizer())
          .listen(_onEvent);

      // sensorOrientation is the clockwise rotation (degrees) to bring the
      // frame upright. On Android (YUV420) the native side needs it; on iOS the
      // BGRA path is already preview-oriented, so 0 is correct there.
      final rotation = Platform.isIOS ? 0 : back.sensorOrientation;

      await controller.startImageStream((image) {
        // Drop frames while the controller/stream is torn down.
        if (!mounted || frames.isClosed) return;
        final input = _toScanInput(image, rotation);
        if (input != null) frames.add(input);
      });

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

  // Converts a CameraImage to the package's ScanInput.cameraFrame. The plane →
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
    switch (event) {
      case DetectionSuccess(:final corners):
        _updateCapture(corners);
        setState(() {
          _corners = corners;
          _error = null;
          _hint = 'Document detected — hold steady.';
        });
      case DetectionEmpty():
        _updateCapture(null);
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

  // Feed corners to the auto-capture analyzer; flash "Captured!" once ready.
  void _updateCapture(DocumentCorners? corners) {
    final state = _analyzer.add(corners);
    _capture = state.status;
    if (state.shouldCapture && !_flashCaptured) {
      _flashCaptured = true;
      // A real app would grab a full-res still + crop here. We just flash.
      Future<void>.delayed(const Duration(milliseconds: 900), () {
        if (mounted) setState(() => _flashCaptured = false);
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
      appBar: AppBar(title: const Text('Realtime overlay')),
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

    return Stack(
      fit: StackFit.expand,
      children: [
        // The preview and overlay share the same box, so normalized corners map
        // straight onto the preview.
        CameraPreview(
          controller,
          child: LayoutBuilder(
            builder: (context, _) => CustomPaint(
              painter: _DocumentOverlayPainter(_corners),
              size: Size.infinite,
            ),
          ),
        ),
        Positioned(
          top: 16,
          left: 16,
          right: 16,
          child: _CaptureChip(status: _capture),
        ),
        Positioned(
          bottom: 24 + bottomInset,
          left: 16,
          right: 16,
          child: Column(
            children: [
              if (_error != null)
                _Banner(_error!, color: Colors.red.shade700)
              else
                _Banner(_hint, color: Colors.black54),
              const SizedBox(height: 8),
              _Banner(
                'Demo: overlay-to-preview alignment is simplified — the quad may '
                'sit rotated on some devices. Detection itself is real.',
                color: Colors.black45,
              ),
            ],
          ),
        ),
        if (_flashCaptured)
          const Center(
            child: _Banner('Captured!', color: Colors.green, large: true),
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
  const _Banner(this.text, {required this.color, this.large = false});

  final String text;
  final Color color;
  final bool large;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: large ? 24 : 14,
        vertical: large ? 16 : 10,
      ),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white,
          fontSize: large ? 22 : 14,
          fontWeight: large ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }
}
