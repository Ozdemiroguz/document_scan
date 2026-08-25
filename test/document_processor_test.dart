import 'dart:math' as math;
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

/// Renders a page of equal-height horizontal bands as if it were *photographed
/// at an angle*, and returns the photo plus the page's corners within it.
///
/// The page is a flat plane in 3D, tilted away from the camera about its
/// horizontal axis, projected through a pinhole. That makes it real ground
/// truth for the warp rather than a formula copied from the implementation: the
/// bands are equally tall ON THE PAGE, the camera foreshortens them (the far
/// edge compresses), and a correct perspective correction has to undo exactly
/// that. A four-corner *bilinear* blend cannot — it pins the corners and
/// interpolates linearly between them, so the recovered bands come out on a
/// ramp instead of even.
({Uint8List bytes, DocumentCorners corners}) _photographedBands({
  int width = 900,
  int height = 700,
  int bands = 10,
  double tilt = 0.9, // radians the page leans away from the sensor plane
  double cameraDistance = 2.2,
  double focal = 1400,
}) {
  // Page point (u, v) in 0..1 -> pixel in the photo.
  ({double x, double y}) project(double u, double v) {
    final px = u - 0.5; // page-local, centred
    final py = v - 0.5;
    final y3 = py * math.cos(tilt); // lean about the horizontal axis…
    final z3 = py * math.sin(tilt); // …so the bottom edge swings toward us
    final depth = cameraDistance - z3;
    return (
      x: focal * px / depth + width / 2,
      y: focal * y3 / depth + height / 2,
    );
  }

  final photo = img.Image(width: width, height: height, numChannels: 3);
  img.fill(photo, color: img.ColorRgb8(0, 0, 0));
  const samples = 1800; // dense enough that the forward scatter leaves no holes
  for (var j = 0; j < samples; j++) {
    final v = j / (samples - 1);
    final light = (v * bands).floor().clamp(0, bands - 1).isEven;
    final tone = light ? 255 : 30;
    for (var i = 0; i < samples; i++) {
      final p = project(i / (samples - 1), v);
      final x = p.x.round(), y = p.y.round();
      // Splat 2x2: at this sample density a single pixel would still leave the
      // odd gap on the near (magnified) edge, which would read as a false band
      // boundary later.
      for (var dy = 0; dy < 2; dy++) {
        for (var dx = 0; dx < 2; dx++) {
          final tx = x + dx, ty = y + dy;
          if (tx < 0 || ty < 0 || tx >= width || ty >= height) continue;
          photo.setPixelRgb(tx, ty, tone, tone, tone);
        }
      }
    }
  }

  final tl = project(0, 0), tr = project(1, 0);
  final br = project(1, 1), bl = project(0, 1);
  return (
    bytes: Uint8List.fromList(img.encodePng(photo)),
    corners: DocumentCorners(
      topLeft: (x: tl.x / width, y: tl.y / height),
      topRight: (x: tr.x / width, y: tr.y / height),
      bottomRight: (x: br.x / width, y: br.y / height),
      bottomLeft: (x: bl.x / width, y: bl.y / height),
    ),
  );
}

/// Rows where a mid-column scan of [image] flips between light and dark.
List<int> _bandBoundaries(img.Image image) {
  final x = image.width ~/ 2;
  final boundaries = <int>[];
  var prev = image.getPixel(x, 0).r > 128;
  for (var y = 1; y < image.height; y++) {
    final cur = image.getPixel(x, y).r > 128;
    if (cur != prev) boundaries.add(y);
    prev = cur;
  }
  return boundaries;
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

    test('caps the output long side at maxDimension by default', () async {
      // A 3000x2000 source cropped full-frame would warp to ~3000x2000; the
      // default cap (2000) must scale it down so the long side is ~2000.
      final bytes = _pngImage(3000, 2000);
      final out = await processor.crop(
        ScanInput.bytes(bytes, width: 3000, height: 2000),
        fullFrame,
      );

      expect(out, isNotNull);
      expect(out!.width, lessThanOrEqualTo(2000));
      expect(out.height, lessThanOrEqualTo(2000));
      // Long side lands right at the cap (within rounding).
      expect(out.width, closeTo(2000, 2));
      // Aspect ratio preserved: 3000:2000 == 3:2, so height ~= 1333.
      expect(out.height, closeTo(1333, 3));
    });

    test('maxDimension: null warps at full resolution', () async {
      final bytes = _pngImage(3000, 2000);
      final out = await processor.crop(
        ScanInput.bytes(bytes, width: 3000, height: 2000),
        fullFrame,
        maxDimension: null,
      );

      expect(out, isNotNull);
      expect(out!.width, closeTo(3000, 2));
      expect(out.height, closeTo(2000, 2));
    });

    test('a custom maxDimension is honoured', () async {
      final bytes = _pngImage(3000, 2000);
      final out = await processor.crop(
        ScanInput.bytes(bytes, width: 3000, height: 2000),
        fullFrame,
        maxDimension: 900,
      );

      expect(out, isNotNull);
      expect(out!.width, closeTo(900, 2));
      expect(out.height, closeTo(600, 2)); // 3:2 preserved
    });

    test('an already-small document is not upscaled by maxDimension', () async {
      // Long side (200) is under the cap → output stays at edge-length size.
      final bytes = _pngImage(200, 120);
      final out = await processor.crop(
        ScanInput.bytes(bytes, width: 200, height: 120),
        fullFrame,
        maxDimension: 2000,
      );

      expect(out, isNotNull);
      expect(out!.width, closeTo(200, 2));
      expect(out.height, closeTo(120, 2));
    });

    test('degenerate output (1px axis) returns a scan, never throws', () async {
      // A very wide, ~flat region: after the size cap the short axis rounds to
      // 1px, which used to divide by (outH-1)==0 → NaN → NaN.toInt() crash.
      // The crop must still return a (tiny) image, honouring its no-throw
      // contract.
      final bytes = _pngImage(4000, 2);
      final out = await processor.crop(
        ScanInput.bytes(bytes, width: 4000, height: 2),
        fullFrame,
      );
      expect(out, isNotNull);
      expect(out!.height, greaterThanOrEqualTo(1));
      expect(out.width, greaterThanOrEqualTo(1));
    });

    test('a collapsed-edge quad does not throw', () async {
      // topLeft == topRight collapses the top edge to a point.
      final bytes = _pngImage(100, 100);
      const collapsed = DocumentCorners(
        topLeft: (x: 0.5, y: 0.5),
        topRight: (x: 0.5, y: 0.5),
        bottomRight: (x: 0.9, y: 0.9),
        bottomLeft: (x: 0.1, y: 0.9),
      );
      final out = await processor.crop(
        ScanInput.bytes(bytes, width: 100, height: 100),
        collapsed,
      );
      // May be a thin sliver, but must not throw.
      expect(out, isNotNull);
    });

    test('returns null for undecodable bytes (does not throw)', () async {
      // Malformed bytes must be swallowed into a null result, per the contract.
      final out = await processor.crop(
        ScanInput.bytes(
          Uint8List.fromList([0, 1, 2, 3]),
          width: 10,
          height: 10,
        ),
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

  group('crop() undoes perspective, not just the corners', () {
    // The regression lock for the warp being a homography. A four-corner
    // bilinear blend passes every other test in this file — it maps the quad
    // onto the output exactly, at the right size and proportions — and still
    // gets the *inside* of a tilted page wrong. Only measuring content spacing
    // catches it. Reference numbers on this scene: projective recovers bands of
    // 42–43 px (ideal 42.5, ratio 1.02); bilinear ramps them 32 → 54 px
    // (ratio 1.69).
    test('equal bands on a tilted page come back equal', () async {
      final scene = _photographedBands();
      final out = await processor.crop(
        ScanInput.bytes(scene.bytes, width: 900, height: 700),
        scene.corners,
      );

      expect(out, isNotNull);
      final decoded = img.decodePng(out!.bytes)!;
      final boundaries = _bandBoundaries(decoded);
      // 10 bands → 9 interior light/dark flips.
      expect(boundaries, hasLength(9));

      final heights = [
        for (var i = 1; i < boundaries.length; i++)
          boundaries[i] - boundaries[i - 1],
      ];
      final ideal = decoded.height / 10;
      // Every recovered band is the same height as every other...
      expect(
        heights.reduce(math.max) / heights.reduce(math.min),
        lessThan(1.15),
        reason:
            'bands ramp instead of staying even — the warp is losing the '
            'perspective division: $heights',
      );
      // ...and that height is the one the page actually had.
      for (final h in heights) {
        expect(h, closeTo(ideal, ideal * 0.08));
      }
    });

    test('a strongly tilted page still lands its corners exactly', () async {
      // The property bilinear also satisfies — kept so a future rewrite can't
      // fix the interior while drifting the edges.
      final scene = _photographedBands(tilt: 1.1);
      final out = await processor.crop(
        ScanInput.bytes(scene.bytes, width: 900, height: 700),
        scene.corners,
      );

      final decoded = img.decodePng(out!.bytes)!;
      // The page's own first band is light, its last is dark; the output's
      // corners must sit inside those, not on the black surround.
      expect(decoded.getPixel(2, 2).r, greaterThan(128));
      expect(decoded.getPixel(decoded.width - 3, 2).r, greaterThan(128));
      expect(decoded.getPixel(2, decoded.height - 3).r, lessThan(128));
      expect(
        decoded.getPixel(decoded.width - 3, decoded.height - 3).r,
        lessThan(128),
      );
    });
  });

  group('background: isolate execution', () {
    // A quad + colored content so the warp does real work, exercised on both
    // the foreground and background paths.
    final quad = [
      (x: 0.15, y: 0.10),
      (x: 0.88, y: 0.18),
      (x: 0.82, y: 0.92),
      (x: 0.12, y: 0.80),
    ];

    test(
      'crop(background: true) runs on an isolate without crashing',
      () async {
        final bytes = _pngImage(
          240,
          200,
          quad: quad,
          quadColor: img.ColorRgb8(200, 30, 30),
        );
        final out = await processor.crop(
          ScanInput.bytes(bytes, width: 240, height: 200),
          DocumentCorners.fromUnordered(quad),
          filter: ScanFilter.enhance,
          background: true,
        );
        expect(out, isNotNull);
        expect(out!.bytes, isNotEmpty);
      },
    );

    test(
      'crop(background: true) is byte-identical to background: false',
      () async {
        final bytes = _pngImage(
          240,
          200,
          quad: quad,
          quadColor: img.ColorRgb8(200, 30, 30),
        );
        final input = ScanInput.bytes(bytes, width: 240, height: 200);
        final corners = DocumentCorners.fromUnordered(quad);

        final fg = await processor.crop(
          input,
          corners,
          filter: ScanFilter.enhance,
          output: const ScanOutputFormat.jpegAt(85),
        );
        final bg = await processor.crop(
          input,
          corners,
          filter: ScanFilter.enhance,
          output: const ScanOutputFormat.jpegAt(85),
          background: true,
        );

        expect(fg, isNotNull);
        expect(bg, isNotNull);
        // Same pixels, same encode → identical bytes: the isolate path is a pure
        // relocation of the same work, not a different result.
        expect(bg!.width, fg!.width);
        expect(bg.height, fg.height);
        expect(bg.bytes, equals(fg.bytes));
      },
    );

    test('applyFilter(background: true) matches background: false', () async {
      final bytes = _pngImage(120, 90, background: img.ColorRgb8(180, 120, 60));
      final input = ScanInput.bytes(bytes, width: 120, height: 90);

      final fg = await processor.applyFilter(input, ScanFilter.grayscale);
      final bg = await processor.applyFilter(
        input,
        ScanFilter.grayscale,
        background: true,
      );
      expect(bg!.bytes, equals(fg!.bytes));
    });

    test(
      'background path preserves the null-on-undecodable contract',
      () async {
        final out = await processor.crop(
          ScanInput.bytes(Uint8List.fromList([9, 9, 9]), width: 4, height: 4),
          fullFrame,
          background: true,
        );
        expect(out, isNull);
      },
    );
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
      expect(
        brightEnd - darkEnd,
        greaterThan(80),
        reason: 'enhance should widen the tonal range',
      );
    });

    test('every filter produces valid, non-empty PNG output', () async {
      for (final f in ScanFilter.values) {
        final out = await processor.applyFilter(
          ScanInput.bytes(colorful, width: 60, height: 60),
          f,
        );
        expect(out, isNotNull, reason: 'filter $f returned null');
        expect(
          img.decodePng(out!.bytes),
          isNotNull,
          reason: 'filter $f bad PNG',
        );
      }
    });

    test('blackWhite really is black and white', () async {
      // The enum promises hard black & white and enhance's docs describe it as
      // "the hard binarization" — a contrast boost that leaves greys behind
      // would break both. Every pixel must land on 0 or 255.
      final page = img.Image(width: 80, height: 80, numChannels: 3);
      for (var y = 0; y < 80; y++) {
        for (var x = 0; x < 80; x++) {
          final v = 90 + x * 2; // a full grey ramp, 90..248
          page.setPixel(x, y, img.ColorRgb8(v, v, v));
        }
      }
      final out = await processor.applyFilter(
        ScanInput.bytes(
          Uint8List.fromList(img.encodePng(page)),
          width: 80,
          height: 80,
        ),
        ScanFilter.blackWhite,
      );
      final result = img.decodePng(out!.bytes)!;

      final tones = <int>{};
      for (var y = 0; y < result.height; y += 3) {
        for (var x = 0; x < result.width; x += 3) {
          tones.add(result.getPixel(x, y).r.toInt());
        }
      }
      expect(
        tones,
        unorderedEquals(<int>[0, 255]),
        reason: 'blackWhite left grey behind: $tones',
      );
    });

    test('blackWhite splits ink from paper on an evenly-lit page', () async {
      final page = img.Image(width: 100, height: 100, numChannels: 3);
      img.fill(page, color: img.ColorRgb8(235, 235, 235)); // even paper
      img.fillRect(
        page,
        x1: 30,
        y1: 30,
        x2: 70,
        y2: 70,
        color: img.ColorRgb8(35, 35, 35),
      ); // ink block
      final out = await processor.applyFilter(
        ScanInput.bytes(
          Uint8List.fromList(img.encodePng(page)),
          width: 100,
          height: 100,
        ),
        ScanFilter.blackWhite,
      );
      final result = img.decodePng(out!.bytes)!;

      expect(result.getPixel(50, 50).r, 0, reason: 'ink not black');
      expect(result.getPixel(5, 5).r, 255, reason: 'paper not white');
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
      img.fillRect(
        page,
        x1: 40,
        y1: 40,
        x2: 60,
        y2: 60,
        color: img.ColorRgb8(20, 20, 20),
      );
      final bytes = Uint8List.fromList(img.encodePng(page));

      final out = await processor.applyFilter(
        ScanInput.bytes(bytes, width: 100, height: 100),
        ScanFilter.magicColor,
      );
      final result = img.decodePng(out!.bytes)!;

      // Ink center -> black; paper on BOTH the dim-left and bright-right sides
      // -> white (a global threshold would blacken the dim-left paper).
      expect(result.getPixel(50, 50).r, lessThan(64), reason: 'ink not black');
      expect(
        result.getPixel(5, 50).r,
        greaterThan(192),
        reason: 'dim paper not white',
      );
      expect(
        result.getPixel(95, 50).r,
        greaterThan(192),
        reason: 'bright paper not white',
      );
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
    setUp(
      () => src = _pngImage(80, 80, background: img.ColorRgb8(120, 60, 200)),
    );

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
        output: ScanOutputFormat.jpegAt(70),
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

    test('pagesToPdf combines N scans into an N-page PDF', () async {
      // Three image scans (as a multi-page ScanSession would collect).
      final pages = <ScannedDocument>[];
      for (var i = 0; i < 3; i++) {
        final page = await processor.crop(
          ScanInput.bytes(src, width: 80, height: 80),
          fullFrame,
          output: const ScanOutputFormat.jpegAt(80),
        );
        pages.add(page!);
      }

      final pdf = await processor.pagesToPdf(pages);
      expect(pdf, isNotNull);
      // Valid PDF header.
      expect(pdf!.bytes.sublist(0, 5), [0x25, 0x50, 0x44, 0x46, 0x2D]);
      // Count `/Type /Page` (not /Pages) objects — one per scan.
      final text = String.fromCharCodes(pdf.bytes);
      final pageCount = RegExp(r'/Type\s*/Page[^s]').allMatches(text).length;
      expect(pageCount, 3);
    });

    test('pagesToPdf returns null for an empty list', () async {
      expect(await processor.pagesToPdf([]), isNull);
    });

    test('lower JPEG quality yields fewer bytes on a detailed image', () async {
      // A noisy image so JPEG quality actually affects size (flat colors don't).
      final noisy = img.Image(width: 120, height: 120, numChannels: 3);
      for (var y = 0; y < 120; y++) {
        for (var x = 0; x < 120; x++) {
          noisy.setPixel(
            x,
            y,
            img.ColorRgb8((x * 7) % 256, (y * 13) % 256, (x * y) % 256),
          );
        }
      }
      final noisyPng = Uint8List.fromList(img.encodePng(noisy));
      final hi = await processor.crop(
        ScanInput.bytes(noisyPng, width: 120, height: 120),
        fullFrame,
        output: ScanOutputFormat.jpegAt(90),
      );
      final lo = await processor.crop(
        ScanInput.bytes(noisyPng, width: 120, height: 120),
        fullFrame,
        output: ScanOutputFormat.jpegAt(30),
      );
      expect(lo!.bytes.length, lessThan(hi!.bytes.length));
    });

    test('ScanOutputFormat rejects out-of-range quality', () {
      expect(
        () => ScanOutputFormat(quality: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => ScanOutputFormat(quality: 101),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
