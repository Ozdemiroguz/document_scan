import 'dart:typed_data';

import 'package:document_scan/document_scan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';

/// A small valid PNG so MemoryImage has real bytes to embed.
ScannedDocument doc(int w, int h) {
  final image = img.Image(width: w, height: h, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(200, 200, 200));
  return ScannedDocument(
    bytes: Uint8List.fromList(img.encodePng(image)),
    width: w,
    height: h,
  );
}

/// The %PDF- magic header marks a valid PDF byte stream.
bool looksLikePdf(Uint8List bytes) =>
    bytes.length > 5 &&
    bytes[0] == 0x25 && // %
    bytes[1] == 0x50 && // P
    bytes[2] == 0x44 && // D
    bytes[3] == 0x46 && // F
    bytes[4] == 0x2D; //  -

void main() {
  const exporter = DocumentPdfExporter();

  test('produces a valid non-empty PDF for a single page', () async {
    final bytes = await exporter.export([doc(200, 280)]);
    expect(looksLikePdf(bytes), isTrue);
    expect(bytes.length, greaterThan(100));
  });

  test('multi-page export is larger than single-page', () async {
    final one = await exporter.export([doc(200, 280)]);
    final three =
        await exporter.export([doc(200, 280), doc(200, 280), doc(200, 280)]);
    expect(looksLikePdf(three), isTrue);
    expect(three.length, greaterThan(one.length));
  });

  test('all page-fit modes produce a valid PDF', () async {
    for (final fit in PdfPageFit.values) {
      final bytes = await exporter.export([doc(300, 200)], fit: fit);
      expect(looksLikePdf(bytes), isTrue, reason: 'fit $fit');
    }
  });

  test('respects a custom page format', () async {
    final bytes = await exporter.export(
      [doc(200, 280)],
      pageFormat: PdfPageFormat.a5,
    );
    expect(looksLikePdf(bytes), isTrue);
  });

  test('empty page list still yields a valid (empty) PDF', () async {
    final bytes = await exporter.export([]);
    expect(looksLikePdf(bytes), isTrue);
  });

  test('exportSession pulls pages from a session in order', () async {
    final session = const ScanSession()
        .add(ScannedPage(document: doc(200, 280)))
        .add(ScannedPage(document: doc(200, 280)));
    final bytes = await exporter.exportSession(session);
    expect(looksLikePdf(bytes), isTrue);
  });
}
