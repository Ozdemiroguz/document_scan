import 'dart:typed_data';

import 'package:document_scan/document_scan.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../scan_isolate.dart';

/// Demonstrates the detect-then-crop flow with the heavy step off the UI thread.
///
/// Pick a photo, run [DocumentDetector.detect] (native, off-thread already),
/// then perspective-correct + filter it via [DocumentProcessor.crop] on a
/// background isolate (see [cropInIsolate]) so the UI stays responsive while the
/// warp runs. The filter dropdown re-crops the same detected corners live.
class GalleryScanScreen extends StatefulWidget {
  const GalleryScanScreen({super.key});

  @override
  State<GalleryScanScreen> createState() => _GalleryScanScreenState();
}

class _GalleryScanScreenState extends State<GalleryScanScreen> {
  // The two composable pieces used directly: the detector finds the corners
  // (native), then cropInIsolate warps + filters off the UI thread.
  final _detector = DocumentDetector();

  // Which enhancement to apply after cropping. `enhance` is the default clean
  // "scanned document" look; the dropdown lets you compare the others live.
  ScanFilter _filter = ScanFilter.enhance;

  String _status = 'Pick a photo of a document to scan.';
  Uint8List? _scannedBytes;
  bool _busy = false;

  Future<void> _pickAndScan() async {
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
      _status = 'Detecting document edges…';
      _scannedBytes = null;
    });

    // Detect on the main isolate (native, non-blocking), then warp + filter on
    // a background isolate so the UI doesn't freeze. Returns null when no
    // document-like rectangle is found.
    final corners = await _detector.detect(ScanInput.file(picked.path));
    final scan = corners == null
        ? null
        : await cropInIsolate(picked.path, corners, filter: _filter);

    if (!mounted) return;
    setState(() {
      _busy = false;
      _scannedBytes = scan?.bytes;
      _status = scan == null
          ? 'No document found. Try a clearer photo on a plain surface.'
          : 'Scanned ${scan.width}×${scan.height} with ${_filter.name}.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gallery scan')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_status, style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Filter: '),
                  DropdownButton<ScanFilter>(
                    value: _filter,
                    onChanged: _busy
                        ? null
                        : (f) {
                            if (f == null) return;
                            setState(() => _filter = f);
                          },
                    items: [
                      for (final f in ScanFilter.values)
                        DropdownMenuItem(value: f, child: Text(f.name)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Center(
                  child: _scannedBytes != null
                      ? Image.memory(_scannedBytes!)
                      : const Icon(Icons.document_scanner_outlined, size: 96),
                ),
              ),
              FilledButton.icon(
                onPressed: _busy ? null : _pickAndScan,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.photo_library_outlined),
                label: Text(_busy ? 'Scanning…' : 'Pick & scan a document'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
