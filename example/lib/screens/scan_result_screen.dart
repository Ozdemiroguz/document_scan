import 'package:document_scan/document_scan.dart';
import 'package:flutter/material.dart';

/// Shows the finished scan — the cropped, perspective-corrected, filtered
/// document that [DocumentScanner.scan] returned. Shared by the realtime
/// auto-capture flow and the camera-capture flow so both end at the same
/// "here's your scan" screen.
///
/// It only *displays* the result (via `Image.memory` on the returned bytes) and
/// offers to scan again — a real app would save/share/upload the bytes here.
class ScanResultScreen extends StatelessWidget {
  const ScanResultScreen({super.key, required this.document});

  /// The scan to show. Its [ScannedDocument.bytes] are standard encoded image
  /// bytes (PNG/JPEG), so `Image.memory` renders them directly.
  final ScannedDocument document;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan result')),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                color: Colors.black12,
                padding: const EdgeInsets.all(16),
                child: InteractiveViewer(
                  // Let the user pinch-zoom to inspect the scanned document.
                  maxScale: 5,
                  child: Center(child: Image.memory(document.bytes)),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${document.width}×${document.height}px · '
                    '${(document.bytes.length / 1024).round()} KB',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.replay),
                    label: const Text('Scan another'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
