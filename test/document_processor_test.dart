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

    test('returns null for an undecodable input', () async {
      final out = await processor.applyFilter(
        ScanInput.bytes(Uint8List.fromList([9, 9]), width: 1, height: 1),
        ScanFilter.grayscale,
      );
      expect(out, isNull);
    });
  });
}
