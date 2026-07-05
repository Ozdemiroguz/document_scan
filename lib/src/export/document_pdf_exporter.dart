import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../session/scan_session.dart';
import '../types/scanned_document.dart';

/// How each scanned page is laid out on its PDF page.
enum PdfPageFit {
  /// Scale the image to fill the page, preserving aspect ratio, cropping any
  /// overflow — no borders, edge to edge.
  cover,

  /// Scale the image to fit inside the page, preserving aspect ratio, leaving
  /// margins where the aspect ratios differ.
  contain,

  /// Size the PDF page to the image itself (no fixed page size). Good for a
  /// "one scan, one exactly-sized page" export.
  actualSize,
}

/// Turns scanned document images into a PDF — the real-world sink for a scan
/// (email, sign, archive).
///
/// Pure Dart via the `pdf` package, and deliberately separate from the detector
/// and processor: it consumes their output ([ScannedDocument] / [ScanSession])
/// and depends on nothing native, so the core stays dependency-light. One image
/// per page, in order.
class DocumentPdfExporter {
  const DocumentPdfExporter();

  /// Builds a PDF from [pages] (each a processed page image) and returns the
  /// encoded bytes.
  ///
  /// [pageFormat] is the fixed page size (default A4) used for [PdfPageFit.cover]
  /// and [PdfPageFit.contain]; it's ignored for [PdfPageFit.actualSize], where
  /// each page matches its image. [margin] (PDF points) applies to `contain`.
  Future<Uint8List> export(
    List<ScannedDocument> pages, {
    PdfPageFormat pageFormat = PdfPageFormat.a4,
    PdfPageFit fit = PdfPageFit.contain,
    double margin = 0,
  }) async {
    final doc = pw.Document();

    for (final page in pages) {
      final image = pw.MemoryImage(page.bytes);

      switch (fit) {
        case PdfPageFit.actualSize:
          // A page sized to the image (at 72 dpi, 1 px = 1 pt).
          final format = PdfPageFormat(
            page.width.toDouble(),
            page.height.toDouble(),
          );
          doc.addPage(
            pw.Page(
              pageFormat: format,
              build: (_) => pw.Image(image, fit: pw.BoxFit.fill),
            ),
          );
        case PdfPageFit.cover:
          doc.addPage(
            pw.Page(
              pageFormat: pageFormat,
              build: (_) => pw.FullPage(
                ignoreMargins: true,
                child: pw.Image(image, fit: pw.BoxFit.cover),
              ),
            ),
          );
        case PdfPageFit.contain:
          doc.addPage(
            pw.Page(
              pageFormat: pageFormat.copyWith(
                marginTop: margin,
                marginBottom: margin,
                marginLeft: margin,
                marginRight: margin,
              ),
              build: (_) => pw.Center(
                child: pw.Image(image, fit: pw.BoxFit.contain),
              ),
            ),
          );
      }
    }

    return doc.save();
  }

  /// Convenience: export every page of a [session] in order.
  Future<Uint8List> exportSession(
    ScanSession session, {
    PdfPageFormat pageFormat = PdfPageFormat.a4,
    PdfPageFit fit = PdfPageFit.contain,
    double margin = 0,
  }) {
    return export(
      [for (final p in session.pages) p.document],
      pageFormat: pageFormat,
      fit: fit,
      margin: margin,
    );
  }
}
