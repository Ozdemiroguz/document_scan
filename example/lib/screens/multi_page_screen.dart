import 'dart:typed_data';

import 'package:document_scan/document_scan.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// Demonstrates a multi-page scan: collect several scans in a [ScanSession],
/// reorder / remove them, then export the whole thing as one PDF with
/// [DocumentProcessor.pagesToPdf].
///
/// [ScanSession] is a plain immutable value type (each edit returns a new
/// session), so it drops straight into `setState` here — no state-management
/// library. "Add pages" picks several images at once and scans each (via the
/// `DocumentScanner.scan` façade, off the UI thread), appending them; "Export
/// PDF" turns the collected pages into a single multi-page PDF.
class MultiPageScreen extends StatefulWidget {
  const MultiPageScreen({super.key});

  @override
  State<MultiPageScreen> createState() => _MultiPageScreenState();
}

class _MultiPageScreenState extends State<MultiPageScreen> {
  final _scanner = DocumentScanner();
  static const _processor = DocumentProcessor();

  // The immutable multi-page container. Each mutation returns a new session.
  ScanSession _session = const ScanSession();

  bool _busy = false;
  String _status = 'Add pages, reorder them, then export a PDF.';

  Future<void> _addPages() async {
    // Pick several images at once — the natural multi-page flow — instead of
    // reopening the gallery per page.
    final picked = await ImagePicker().pickMultiImage(
      maxWidth: 2000,
      maxHeight: 2000,
    );
    if (picked.isEmpty) return;
    setState(() {
      _busy = true;
      _status = 'Scanning ${picked.length} image(s)…';
    });

    // Scan each picked image to a clean JPEG page and append it. A page with no
    // detectable document is skipped (counted below) rather than aborting.
    var skipped = 0;
    for (final file in picked) {
      final scan = await _scanner.scan(
        ScanInput.file(file.path),
        output: const ScanOutputFormat.jpegAt(85),
      );
      if (!mounted) return;
      if (scan == null) {
        skipped++;
      } else {
        setState(() => _session = _session.add(ScannedPage(document: scan)));
      }
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      final skipNote = skipped == 0 ? '' : ' ($skipped had no document)';
      _status =
          '${_session.length} page(s)$skipNote. Reorder, remove, or export.';
    });
  }

  Future<void> _exportPdf() async {
    if (_session.isEmpty) return;
    setState(() {
      _busy = true;
      _status = 'Building PDF…';
    });

    // One A4 page per collected scan, in the session's order.
    final pdf = await _processor.pagesToPdf([
      for (final page in _session.pages) page.document,
    ]);

    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = pdf == null
          ? 'Nothing to export.'
          : '${_session.length} page(s) ready to export.';
    });

    if (pdf == null) return;
    final pageCount = _session.length;
    final kb = (pdf.bytes.length / 1024).toStringAsFixed(0);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.picture_as_pdf, size: 40, color: Colors.teal),
        title: const Text('PDF ready'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$pageCount page${pageCount == 1 ? '' : 's'} · $kb KB',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            const Text(
              'pagesToPdf returned the PDF as bytes. From here a real app would '
              'save it (path_provider), share it (share_plus), or preview/print '
              'it (printing) — this demo stays dependency-light and stops at the '
              'bytes.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Multi-page session')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_status, style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 12),
              Expanded(child: _buildPages()),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _addPages,
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                      label: const Text('Add pages'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: (_busy || _session.isEmpty)
                          ? null
                          : _exportPdf,
                      icon: const Icon(Icons.picture_as_pdf_outlined),
                      label: Text('Export PDF (${_session.length})'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPages() {
    if (_session.isEmpty) {
      return const Center(child: Icon(Icons.collections_outlined, size: 96));
    }
    // A reorderable list of page thumbnails — drag to reorder (session.reorder),
    // tap the trash to remove (session.removeAt).
    //
    // ScanSession.reorder is documented to take the classic ReorderableListView
    // indices (newIndex is the pre-removal target, 0..length). The old
    // `onReorder` passes exactly those, so we use it deliberately; the newer
    // `onReorderItem` pre-adjusts newIndex, which would double-correct against
    // reorder()'s own adjustment.
    // ignore: deprecated_member_use
    return ReorderableListView.builder(
      itemCount: _session.length,
      // ignore: deprecated_member_use
      onReorder: (oldIndex, newIndex) => setState(() {
        _session = _session.reorder(oldIndex, newIndex);
      }),
      itemBuilder: (context, i) {
        final page = _session.pages[i];
        return Card(
          key: ValueKey(page),
          child: ListTile(
            leading: _Thumb(page.document.bytes),
            title: Text('Page ${i + 1}'),
            subtitle: Text('${page.document.width}×${page.document.height}'),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _session = _session.removeAt(i);
                      _status = _session.isEmpty
                          ? 'Add pages, reorder them, then export a PDF.'
                          : '${_session.length} page(s).';
                    }),
            ),
          ),
        );
      },
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb(this.bytes);

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.memory(bytes, fit: BoxFit.cover),
      ),
    );
  }
}
