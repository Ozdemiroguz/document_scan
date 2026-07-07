import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:document_scan/document_scan.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../widgets/draggable_corner_overlay.dart';

/// Demonstrates the detect → adjust → crop-with-corners workflow.
///
/// Uses [DocumentDetector.detect] for an initial guess (falling back to an inset
/// quad when nothing is found), lets the user drag the four corners to correct
/// the detection, then passes those edited corners to [DocumentScanner.scan] via
/// its `corners:` argument — which skips detection and crops exactly what the
/// user set (on a background isolate, per scan's default). This is the "the
/// auto-detect was slightly off, let me fix it" path.
class ManualEditScreen extends StatefulWidget {
  const ManualEditScreen({super.key});

  @override
  State<ManualEditScreen> createState() => _ManualEditScreenState();
}

class _ManualEditScreenState extends State<ManualEditScreen> {
  final _detector = DocumentDetector();
  final _scanner = DocumentScanner();

  String? _imagePath;
  // Intrinsic pixel size of the picked image, needed so the overlay's
  // FittedBox(contain) → SizedBox layout maps normalized coords to pixels.
  Size? _imageSize;
  DocumentCorners? _corners;

  Uint8List? _croppedBytes;
  bool _busy = false;
  String _status = 'Pick a photo, adjust the corners, then crop.';

  // A sensible inset quad used when detection finds nothing, so the user always
  // has a draggable starting rectangle.
  static const DocumentCorners _defaultQuad = DocumentCorners(
    topLeft: (x: 0.15, y: 0.15),
    topRight: (x: 0.85, y: 0.15),
    bottomRight: (x: 0.85, y: 0.85),
    bottomLeft: (x: 0.15, y: 0.85),
  );

  Future<void> _pick() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      // A document scan is legible well below full-sensor resolution, and a
      // 12MP+ pick is slow to load and warp. 2000px keeps it snappy.
      maxWidth: 2000,
      maxHeight: 2000,
    );
    if (picked == null) return;
    setState(() {
      _busy = true;
      _status = 'Detecting corners…';
      _croppedBytes = null;
      _corners = null;
      _imageSize = null;
      _imagePath = picked.path;
    });

    // Resolve the intrinsic size (for the overlay layout) and the initial
    // corners in parallel.
    final size = await _decodeSize(picked.path);
    final detected = await _detector.detect(ScanInput.file(picked.path));

    if (!mounted) return;
    setState(() {
      _busy = false;
      _imageSize = size;
      _corners = detected ?? _defaultQuad;
      _status = detected == null
          ? 'No document detected — drag the corners to frame it.'
          : 'Detected. Drag any corner to fine-tune, then crop.';
    });
  }

  Future<Size?> _decodeSize(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final size = Size(image.width.toDouble(), image.height.toDouble());
      image.dispose();
      return size;
    } catch (_) {
      return null;
    }
  }

  // Replace one corner (0=TL, 1=TR, 2=BR, 3=BL) with a new normalized point.
  void _moveCorner(int index, ({double x, double y}) point) {
    final c = _corners;
    if (c == null) return;
    setState(() {
      _corners = switch (index) {
        0 => c.copyWith(topLeft: point),
        1 => c.copyWith(topRight: point),
        2 => c.copyWith(bottomRight: point),
        _ => c.copyWith(bottomLeft: point),
      };
    });
  }

  Future<void> _crop() async {
    final path = _imagePath;
    final corners = _corners;
    if (path == null || corners == null) return;
    setState(() {
      _busy = true;
      _status = 'Cropping with your corners…';
      _croppedBytes = null;
    });

    // Passing corners: skips detection — scan warps with exactly the user's
    // quad. background defaults true, so the crop stays off the UI thread.
    final scan = await _scanner.scan(ScanInput.file(path), corners: corners);

    if (!mounted) return;
    setState(() {
      _busy = false;
      _croppedBytes = scan?.bytes;
      _status = scan == null
          ? 'Could not crop — check the image.'
          : 'Cropped ${scan.width}×${scan.height}. '
                'Tap “Adjust corners” to refine.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manual corner edit')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_status, style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 12),
              Expanded(child: Center(child: _buildStage())),
              const SizedBox(height: 12),
              _buildActions(),
            ],
          ),
        ),
      ),
    );
  }

  // Return to the adjust view (keeps the same corners) so the user can nudge
  // them and crop again — instead of being stuck on the result.
  void _reAdjust() => setState(() {
    _croppedBytes = null;
    _status = 'Drag any corner to fine-tune, then crop.';
  });

  Widget _buildActions() {
    // After a crop: let the user go back and adjust, or pick a new image.
    if (_croppedBytes != null) {
      return Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _pick,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('New image'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              onPressed: _busy ? null : _reAdjust,
              icon: const Icon(Icons.tune),
              label: const Text('Adjust corners'),
            ),
          ),
        ],
      );
    }

    // Adjust view: pick, or crop with the current corners.
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _busy ? null : _pick,
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('Pick image'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.icon(
            onPressed: (_busy || _corners == null) ? null : _crop,
            icon: const Icon(Icons.crop),
            label: const Text('Crop'),
          ),
        ),
      ],
    );
  }

  Widget _buildStage() {
    // After a crop, show the result.
    if (_croppedBytes != null) {
      return Image.memory(_croppedBytes!);
    }

    final path = _imagePath;
    final size = _imageSize;
    final corners = _corners;
    if (path == null) {
      return const Icon(Icons.crop_free, size: 96);
    }
    if (size == null || corners == null) {
      return const CircularProgressIndicator();
    }

    // FittedBox(contain) scales the SizedBox(imageSize) down to fit while
    // preserving aspect; because the overlay is a sibling of the Image inside
    // that same SizedBox, its normalized-coords → pixels mapping stays exact.
    return FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(File(path), fit: BoxFit.fill),
            DraggableCornerOverlay(
              corners: corners,
              onCornerMoved: _moveCorner,
            ),
          ],
        ),
      ),
    );
  }
}
