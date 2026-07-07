import 'dart:typed_data';

import 'package:document_scan/document_scan.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// Demonstrates the one-call façade: [DocumentScanner.scan].
///
/// Pick a photo from the gallery, hand its path to `scanner.scan(...)`, and the
/// package detects the document's corners, perspective-corrects it, applies the
/// chosen [ScanFilter], and returns encoded bytes — all in one call. The filter
/// dropdown lets you compare the looks live (each change re-scans).
class GalleryScanScreen extends StatefulWidget {
  const GalleryScanScreen({super.key});

  @override
  State<GalleryScanScreen> createState() => _GalleryScanScreenState();
}

class _GalleryScanScreenState extends State<GalleryScanScreen> {
  // The one-call façade: detect corners + perspective-correct + filter. Both
  // underlying pieces (DocumentDetector, DocumentProcessor) are still usable on
  // their own — see the "compose the pieces yourself" README section and the
  // other demo screens.
  final _scanner = DocumentScanner();

  // Which enhancement to apply after cropping. `enhance` is the default clean
  // "scanned document" look; the dropdown lets you compare the others live.
  ScanFilter _filter = ScanFilter.enhance;

  String _status = 'Pick a photo of a document to scan.';
  Uint8List? _scannedBytes;
  bool _busy = false;

  Future<void> _pickAndScan() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    setState(() {
      _busy = true;
      _status = 'Detecting document edges…';
      _scannedBytes = null;
    });

    // One call: finds the document, warps it upright, applies the filter, and
    // returns encoded bytes. Returns null when no document-like rectangle is
    // found (e.g. a cluttered scene or a non-document photo).
    final scan = await _scanner.scan(
      ScanInput.file(picked.path),
      filter: _filter,
    );

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
      body: Padding(
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
    );
  }
}
