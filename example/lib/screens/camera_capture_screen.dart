import 'package:camera/camera.dart';
import 'package:document_scan/document_scan.dart';
import 'package:flutter/material.dart';

import 'scan_result_screen.dart';

/// Capture a document straight from the camera (not the gallery): frame it in a
/// live preview, tap the shutter, and the package detects + crops + corrects it.
///
/// This is the one-shot counterpart to the realtime overlay screen. It drives
/// the `camera` plugin for a live preview and a full-resolution still, then hands
/// that still to [DocumentScanner.scan] — the same one call the gallery screen
/// uses, just sourced from the camera. The result opens in [ScanResultScreen].
class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({super.key});

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen>
    with WidgetsBindingObserver {
  final _scanner = DocumentScanner();

  CameraController? _controller;
  bool _ready = false;
  bool _busy = false; // shutter pressed → capturing/scanning
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  Future<void> _start() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      // A still capture — no image stream here, so a high preset is fine; the
      // package downscales internally for detection.
      final controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
      );
      _controller = controller;
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _ready = true);
    } on CameraException catch (e) {
      _fail('Camera unavailable: ${e.description ?? e.code}.');
    } catch (e) {
      _fail('Could not start the camera: $e');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _ready = false;
      _error = message;
    });
  }

  Future<void> _captureAndScan() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _busy) return;
    setState(() => _busy = true);
    try {
      // Full-resolution still, then the one-call façade: detect + warp + filter.
      // The heavy warp runs off the UI thread automatically (background: true).
      final photo = await controller.takePicture();
      final scan = await _scanner.scan(ScanInput.file(photo.path));

      if (!mounted) return;
      if (scan == null) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No document found. Fill the frame on a plain background.',
            ),
          ),
        );
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ScanResultScreen(document: scan),
        ),
      );
      // Back from the result screen — ready to capture again.
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Capture failed: $e')));
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null) return;
    if (state == AppLifecycleState.inactive) {
      controller.dispose();
      _controller = null;
      if (mounted) setState(() => _ready = false);
    } else if (state == AppLifecycleState.resumed) {
      _start();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Camera capture')),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    final controller = _controller;
    if (!_ready || controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Expanded(
          child: Stack(
            alignment: Alignment.center,
            children: [
              Center(child: CameraPreview(controller)),
              if (_busy)
                Container(
                  color: Colors.black45,
                  alignment: Alignment.center,
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text(
                        'Scanning…',
                        style: TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              const Text('Frame the document, then tap to scan.'),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _busy ? null : _captureAndScan,
                icon: const Icon(Icons.camera_alt),
                label: const Text('Capture & scan'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
