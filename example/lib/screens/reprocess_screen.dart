import 'dart:typed_data';

import 'package:document_scan/document_scan.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../scan_isolate.dart';

/// Demonstrates re-filtering the SAME scan cheaply.
///
/// Corner detection is the expensive part (a native round-trip). Here we run
/// [DocumentDetector.detect] ONCE per picked image to get the corners, then feed
/// those cached corners to [DocumentProcessor.crop] on every filter change — so
/// swapping filters only re-warps + re-filters, never re-detects. This is the
/// composed-pieces counterpart to the one-call [DocumentScanner].
class ReprocessScreen extends StatefulWidget {
  const ReprocessScreen({super.key});

  @override
  State<ReprocessScreen> createState() => _ReprocessScreenState();
}

class _ReprocessScreenState extends State<ReprocessScreen> {
  // Detect once (native), then re-crop with cropInIsolate on each filter change
  // — the "detect once, crop many" split, with the crop off the UI thread.
  final _detector = DocumentDetector();

  String? _imagePath;
  // Cached across filter changes — computed once, never re-detected.
  DocumentCorners? _corners;

  ScanFilter _filter = ScanFilter.enhance;
  Uint8List? _resultBytes;
  bool _busy = false;
  String _status = 'Pick a photo — detection runs once, then swap filters.';

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
      _status = 'Detecting corners (once)…';
      _resultBytes = null;
      _corners = null;
      _imagePath = picked.path;
    });

    // The single, cached detection.
    final corners = await _detector.detect(ScanInput.file(picked.path));
    if (!mounted) return;

    if (corners == null) {
      setState(() {
        _busy = false;
        _status = 'No document found. Try a clearer photo.';
      });
      return;
    }

    _corners = corners;
    await _reprocess(); // do the first crop with the default filter
  }

  // Re-crop with the cached corners and the current filter. No detection here —
  // that's the whole point of the demo.
  Future<void> _reprocess() async {
    final path = _imagePath;
    final corners = _corners;
    if (path == null || corners == null) return;
    setState(() {
      _busy = true;
      _status = 'Applying ${_filter.name} (no re-detection)…';
    });

    // Same cached corners, new filter — warp + filter on a background isolate
    // so swapping filters never freezes the UI. No detection here.
    final scan = await cropInIsolate(path, corners, filter: _filter);

    if (!mounted) return;
    setState(() {
      _busy = false;
      _resultBytes = scan?.bytes;
      _status = scan == null
          ? 'Could not process the image.'
          : 'Filter “${_filter.name}” — corners reused, no re-detection.';
    });
  }

  void _onFilterChanged(ScanFilter? f) {
    if (f == null || f == _filter) return;
    setState(() => _filter = f);
    _reprocess();
  }

  @override
  Widget build(BuildContext context) {
    final hasScan = _corners != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Reprocess with filter')),
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
                    // Disabled until we have cached corners to reprocess.
                    onChanged: (_busy || !hasScan) ? null : _onFilterChanged,
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
                  child: _resultBytes != null
                      ? Image.memory(_resultBytes!)
                      : const Icon(Icons.tune, size: 96),
                ),
              ),
              FilledButton.icon(
                onPressed: _busy ? null : _pick,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.photo_library_outlined),
                label: Text(_busy ? 'Working…' : 'Pick & detect a document'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
