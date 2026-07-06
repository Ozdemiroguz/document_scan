import 'dart:typed_data';

import 'package:document_scan/document_scan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Encodes a solid-color test image to PNG bytes so it can be fed as a
/// [ScanInput.bytes]. Optionally paints a filled quad in a second color so a
/// warp can be checked for content, not just dimensions.
Uint8List _pngImage(
  int width,
  int height, {
  img.Color? background,
  List<({double x, double y})>? quad,
  img.Color? quadColor,
}) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: background ?? img.ColorRgb8(255, 255, 255));
  if (quad != null && quadColor != null) {
    final pts = quad
        .map((p) => img.Point(p.x * width, p.y * height))
        .toList(growable: false);
    img.fillPolygon(image, vertices: pts, color: quadColor);
  }
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  const processor = DocumentProcessor();

  // A full-frame quad (the whole image is the document).
  final fullFrame = DocumentCorners.fromUnordered([
    (x: 0.0, y: 0.0),
    (x: 1.0, y: 0.0),
    (x: 1.0, y: 1.0),
    (x: 0.0, y: 1.0),
  ]);

  group('crop() perspective warp', () {
    test('full-frame quad returns an image close to the source size', () async {
      final bytes = _pngImage(200, 120);
      final out = await processor.crop(
        ScanInput.bytes(bytes, width: 200, height: 120),
        fullFrame,
      );

      expect(out, isNotNull);
      // Output is sized from edge lengths (~the full frame), within rounding.
      expect(out!.width, closeTo(200, 2));
      expect(out.height, closeTo(120, 2));
      expect(out.bytes, isNotEmpty);
    });

    test('output proportions follow the quad, not the source', () async {
      // A wide source, but a tall sub-quad → output should be taller than wide.
      final bytes = _pngImage(400, 400);
      final tallQuad = DocumentCorners.fromUnordered([
        (x: 0.40, y: 0.05),
        (x: 0.60, y: 0.05),
        (x: 0.60, y: 0.95),
        (x: 0.40, y: 0.95),
      ]);
      final out = await processor.crop(
        ScanInput.bytes(bytes, width: 400, height: 400),
        tallQuad,
      );

      expect(out, isNotNull);
      expect(out!.height, greaterThan(out.width));
    });

    test('warps a skewed document region to an upright rectangle', () async {
      // Paint a red quad on white; crop exactly that quad. The result should be
      // (almost) entirely red — i.e. the warp mapped the quad to fill the frame.
      final quad = [
        (x: 0.20, y: 0.10),
        (x: 0.85, y: 0.20),
        (x: 0.80, y: 0.90),
        (x: 0.15, y: 0.80),
      ];
      final bytes = _pngImage(
        300,
        300,
        quad: quad,
        quadColor: img.ColorRgb8(255, 0, 0),
      );
      final corners = DocumentCorners.fromUnordered(quad);
      final out = await processor.crop(
        ScanInput.bytes(bytes, width: 300, height: 300),
        corners,
      );

      expect(out, isNotNull);
      final decoded = img.decodePng(out!.bytes)!;
      // Sample the center — it must be red (inside the warped document).
      final center = decoded.getPixel(decoded.width ~/ 2, decoded.height ~/ 2);
      expect(center.r, greaterThan(180));
      expect(center.g, lessThan(80));
      expect(center.b, lessThan(80));
    });

    test('returns null for undecodable bytes (does not throw)', () async {
      // Malformed bytes must be swallowed into a null result, per the contract.
      final out = await processor.crop(
        ScanInput.bytes(Uint8List.fromList([0, 1, 2, 3]), width: 10, height: 10),
        fullFrame,
      );
      expect(out, isNull);
    });

    test('returns null for a raw camera frame (not supported)', () async {
      final out = await processor.crop(
        ScanInput.cameraFrame(
          width: 100,
          height: 100,
          format: ScanImageFormat.bgra8888,
          bytes: Uint8List(40000),
        ),
        fullFrame,
      );
      expect(out, isNull);
    });
  });

  group('applyFilter()', () {
    late Uint8List colorful;

    setUp(() {
      // A mid-gray image so grayscale/contrast changes are observable.
      colorful = _pngImage(60, 60, background: img.ColorRgb8(120, 60, 200));
    });

    test('none returns a decodable image unchanged in size', () async {
      final out = await processor.applyFilter(
        ScanInput.bytes(colorful, width: 60, height: 60),
        ScanFilter.none,
      );
      expect(out, isNotNull);
      expect(out!.width, 60);
      expect(out.height, 60);
    });

    test('grayscale makes R==G==B at every sampled pixel', () async {
      final out = await processor.applyFilter(
        ScanInput.bytes(colorful, width: 60, height: 60),
        ScanFilter.grayscale,
      );
      final decoded = img.decodePng(out!.bytes)!;
      final p = decoded.getPixel(30, 30);
      expect(p.r, closeTo(p.g, 1));
      expect(p.g, closeTo(p.b, 1));
    });

    test('enhance stretches a low-contrast image toward full range', () async {
      // A flat, low-contrast gray gradient (values ~100..150) — the kind of
      // dull photographed-paper input where normalize + contrast earn their
      // keep. After enhance, the histogram should span much closer to 0..255.
      final dull = img.Image(width: 100, height: 100, numChannels: 3);
      for (var y = 0; y < 100; y++) {
        for (var x = 0; x < 100; x++) {
          final v = 100 + (x * 50 ~/ 100); // 100..150, very low contrast
          dull.setPixel(x, y, img.ColorRgb8(v, v, v));
        }
      }
      final bytes = Uint8List.fromList(img.encodePng(dull));

      final out = await processor.applyFilter(
        ScanInput.bytes(bytes, width: 100, height: 100),
        ScanFilter.enhance,
      );
      final result = img.decodePng(out!.bytes)!;

      // Sample the dark and bright ends; the spread must be wider than the
      // original ~50-level range (contrast + normalize pushed them apart).
      final darkEnd = result.getPixel(2, 50).r;
      final brightEnd = result.getPixel(97, 50).r;
      expect(brightEnd - darkEnd, greaterThan(80),
          reason: 'enhance should widen the tonal range');
    });

    test('every filter produces valid, non-empty PNG output', () async {
      for (final f in ScanFilter.values) {
        final out = await processor.applyFilter(
          ScanInput.bytes(colorful, width: 60, height: 60),
          f,
        );
        expect(out, isNotNull, reason: 'filter $f returned null');
        expect(img.decodePng(out!.bytes), isNotNull, reason: 'filter $f bad PNG');
      }
    });

    test('magicColor binarizes ink vs paper under a lighting gradient', () async {
      // Paper with a left-to-right brightness gradient (uneven light) and a dark
      // ink square in the middle — the exact case a global threshold smears.
      final page = img.Image(width: 100, height: 100, numChannels: 3);
      for (var y = 0; y < 100; y++) {
        for (var x = 0; x < 100; x++) {
          // Bright paper, darker on the left (120) to full-bright on the right.
          final base = 120 + (x * 135 ~/ 100);
          page.setPixel(x, y, img.ColorRgb8(base, base, base));
        }
      }
      // A dark ink block at center.
      img.fillRect(page, x1: 40, y1: 40, x2: 60, y2: 60,
          color: img.ColorRgb8(20, 20, 20));
      final bytes = Uint8List.fromList(img.encodePng(page));

      final out = await processor.applyFilter(
        ScanInput.bytes(bytes, width: 100, height: 100),
        ScanFilter.magicColor,
      );
      final result = img.decodePng(out!.bytes)!;

      // Ink center -> black; paper on BOTH the dim-left and bright-right sides
      // -> white (a global threshold would blacken the dim-left paper).
      expect(result.getPixel(50, 50).r, lessThan(64), reason: 'ink not black');
      expect(result.getPixel(5, 50).r, greaterThan(192), reason: 'dim paper not white');
      expect(result.getPixel(95, 50).r, greaterThan(192), reason: 'bright paper not white');
    });

    test('returns null for an undecodable input', () async {
      final out = await processor.applyFilter(
        ScanInput.bytes(Uint8List.fromList([9, 9]), width: 1, height: 1),
        ScanFilter.grayscale,
      );
      expect(out, isNull);
    });
  });

  group('output format', () {
    late Uint8List src;
    setUp(() => src = _pngImage(80, 80, background: img.ColorRgb8(120, 60, 200)));

    test('default output is PNG', () async {
      final out = await processor.crop(
        ScanInput.bytes(src, width: 80, height: 80),
        fullFrame,
      );
      // PNG magic: 0x89 'P' 'N' 'G'.
      expect(out!.bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });

    test('JPEG output emits a valid JPEG', () async {
      final jpeg = await processor.crop(
        ScanInput.bytes(src, width: 80, height: 80),
        fullFrame,
        output: const ScanOutputFormat.jpeg(quality: 70),
      );
      // JPEG magic: 0xFF 0xD8 … 0xFF 0xD9.
      expect(jpeg!.bytes.sublist(0, 2), [0xFF, 0xD8]);
      expect(jpeg.bytes.sublist(jpeg.bytes.length - 2), [0xFF, 0xD9]);
      expect(jpeg.width, 80);
    });

    test('PDF output emits a valid single-page PDF', () async {
      final out = await processor.crop(
        ScanInput.bytes(src, width: 80, height: 80),
        fullFrame,
        output: ScanOutputFormat.pdf,
      );
      // PDF magic header: %PDF-
      expect(out!.bytes.sublist(0, 5), [0x25, 0x50, 0x44, 0x46, 0x2D]);
      expect(out.bytes.length, greaterThan(100));
    });

    test('lower JPEG quality yields fewer bytes on a detailed image', () async {
      // A noisy image so JPEG quality actually affects size (flat colors don't).
      final noisy = img.Image(width: 120, height: 120, numChannels: 3);
      for (var y = 0; y < 120; y++) {
        for (var x = 0; x < 120; x++) {
          noisy.setPixel(x, y, img.ColorRgb8((x * 7) % 256, (y * 13) % 256, (x * y) % 256));
        }
      }
      final noisyPng = Uint8List.fromList(img.encodePng(noisy));
      final hi = await processor.crop(
        ScanInput.bytes(noisyPng, width: 120, height: 120),
        fullFrame,
        output: const ScanOutputFormat.jpeg(quality: 90),
      );
      final lo = await processor.crop(
        ScanInput.bytes(noisyPng, width: 120, height: 120),
        fullFrame,
        output: const ScanOutputFormat.jpeg(quality: 30),
      );
      expect(lo!.bytes.length, lessThan(hi!.bytes.length));
    });

    test('ScanOutputFormat rejects out-of-range quality', () {
      expect(() => ScanOutputFormat(quality: 0), throwsA(isA<AssertionError>()));
      expect(
        () => ScanOutputFormat(quality: 101),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
