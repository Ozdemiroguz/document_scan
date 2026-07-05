import 'dart:typed_data';

import 'package:document_scan/document_scan.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

void main() => runApp(const DocumentScanExampleApp());

class DocumentScanExampleApp extends StatelessWidget {
  const DocumentScanExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'document_scan example',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const ScanDemoPage(),
    );
  }
}

class ScanDemoPage extends StatefulWidget {
  const ScanDemoPage({super.key});

  @override
  State<ScanDemoPage> createState() => _ScanDemoPageState();
}

class _ScanDemoPageState extends State<ScanDemoPage> {
  // The two composable pieces — used independently.
  final _detector = DocumentDetector();
  final _processor = const DocumentProcessor();

  String _status = 'Pick a photo of a document to scan.';
  DocumentCorners? _corners;
  Uint8List? _scannedBytes;
  bool _busy = false;

  Future<void> _pickAndScan() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    setState(() {
      _busy = true;
      _status = 'Detecting document edges…';
      _corners = null;
      _scannedBytes = null;
    });

    final input = ScanInput.file(picked.path);

    // 1) Detect the four corners.
    final corners = await _detector.detect(input);
    if (corners == null) {
      setState(() {
        _busy = false;
        _status = 'No document found. Try a clearer photo on a plain surface.';
      });
      return;
    }

    // 2) Perspective-correct + filter to a clean scan.
    final scanned = await _processor.crop(
      input,
      corners,
      filter: ScanFilter.blackWhite,
    );

    setState(() {
      _busy = false;
      _corners = corners;
      _scannedBytes = scanned?.bytes;
      _status = scanned == null
          ? 'Corners found, but the image could not be processed.'
          : 'Scanned ${scanned.width}×${scanned.height}.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('document_scan')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_status, style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 12),
            if (_corners != null)
              Text(
                'Corners (normalized): $_corners',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 16),
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
