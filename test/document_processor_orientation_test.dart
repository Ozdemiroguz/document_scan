import 'dart:io';

import 'package:document_scan/document_scan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Writes a JPEG whose *raw* pixels are [raw], tagged with EXIF [orientation],
/// into [dir], and returns its path. `orientation: 6` = rotate 90° CW to
/// display upright — the common iPhone-portrait case.
String writeJpegWithOrientation(Directory dir, img.Image raw, int orientation) {
  raw.exif.imageIfd.orientation = orientation;
  final path = '${dir.path}/img_$orientation.jpg';
  File(path).writeAsBytesSync(img.encodeJpg(raw));
  return path;
}

/// A landscape image: left half red, right half white. After baking an
/// orientation the red block lands in a predictable place we can assert on.
img.Image leftRedImage({int width = 80, int height = 40}) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  img.fillRect(
    image,
    x1: 0,
    y1: 0,
    x2: width ~/ 2 - 1,
    y2: height - 1,
    color: img.ColorRgb8(255, 0, 0),
  );
  return image;
}

double _fractionMatching(img.Image image, bool Function(img.Pixel) test) {
  var hit = 0;
  var total = 0;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      total++;
      if (test(image.getPixel(x, y))) hit++;
    }
  }
  return total == 0 ? 0 : hit / total;
}

bool isMostlyRed(img.Image image) =>
    _fractionMatching(image, (p) => p.r > 180 && p.g < 80 && p.b < 80) > 0.6;

bool isMostlyWhite(img.Image image) =>
    _fractionMatching(image, (p) => p.r > 180 && p.g > 180 && p.b > 180) > 0.6;

/// Regression tests for the EXIF-orientation contract of the file crop path.
///
/// The detector reports corners in EXIF-*oriented* (upright) space — Apple
/// Vision applies the file's orientation and the Android native side bakes it
/// before detecting. So the crop must sample pixels in that same oriented
/// space, or an iPhone portrait photo (EXIF 6/8) warps 90° off. The `image`
/// package's decoders already apply EXIF on decode and clear the tag, so
/// [DocumentProcessor] gets upright pixels — these tests lock that behaviour so
/// a future decoder regression (or a wrong "optimization" that skips it) is
/// caught: if EXIF stops being applied, an explicit `bakeOrientation` is needed.
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ds_orient_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  const processor = DocumentProcessor();

  test(
    'crop of an EXIF-orientation-6 file selects the ORIENTED region, not the '
    'raw-sensor region',
    () async {
      // Raw sensor pixels: 80x40 landscape, LEFT half red. EXIF 6 means "rotate
      // 90° CW to display", so the upright (oriented) image is 40x80 portrait
      // with the red band on TOP.
      final raw = leftRedImage();
      final path = writeJpegWithOrientation(tempDir, raw, 6);

      // Corners covering the TOP half of the *oriented* portrait image.
      const orientedTopHalf = DocumentCorners(
        topLeft: (x: 0.0, y: 0.0),
        topRight: (x: 1.0, y: 0.0),
        bottomRight: (x: 1.0, y: 0.5),
        bottomLeft: (x: 0.0, y: 0.5),
      );

      final scanned = await processor.crop(
        ScanInput.file(path),
        orientedTopHalf,
        filter: ScanFilter.none,
      );
      expect(scanned, isNotNull);
      final cropped = img.decodeImage(scanned!.bytes)!;

      // ORIENTED interpretation: top half is the red band → crop is red.
      // If the processor had instead sampled the RAW 80x40 pixels, these same
      // normalized corners (top half of a landscape whose red is on the LEFT)
      // would select a half-red/half-white band — NOT mostly red. So asserting
      // "mostly red" fails unless the crop honoured the orientation.
      expect(
        isMostlyRed(cropped),
        isTrue,
        reason: 'top-half corners must select the oriented red band; a '
            'raw-sensor crop of these same corners would be ~half red / half '
            'white, so "mostly red" fails if orientation is not applied before '
            'the warp',
      );
    },
  );

  test(
    'crop of an EXIF-orientation-6 file: oriented BOTTOM half is white',
    () async {
      // Complementary check: the oriented bottom half is the white band.
      final raw = leftRedImage();
      final path = writeJpegWithOrientation(tempDir, raw, 6);

      const orientedBottomHalf = DocumentCorners(
        topLeft: (x: 0.0, y: 0.5),
        topRight: (x: 1.0, y: 0.5),
        bottomRight: (x: 1.0, y: 1.0),
        bottomLeft: (x: 0.0, y: 1.0),
      );

      final scanned = await processor.crop(
        ScanInput.file(path),
        orientedBottomHalf,
        filter: ScanFilter.none,
      );
      expect(scanned, isNotNull);
      expect(isMostlyWhite(img.decodeImage(scanned!.bytes)!), isTrue);
    },
  );

  test('orientation 1 (upright) file crops the left-half red band', () async {
    final raw = leftRedImage();
    final path = writeJpegWithOrientation(tempDir, raw, 1);

    // Un-rotated 80x40, red on the left → left-half corners are red.
    const leftHalf = DocumentCorners(
      topLeft: (x: 0.0, y: 0.0),
      topRight: (x: 0.5, y: 0.0),
      bottomRight: (x: 0.5, y: 1.0),
      bottomLeft: (x: 0.0, y: 1.0),
    );

    final scanned = await processor.crop(
      ScanInput.file(path),
      leftHalf,
      filter: ScanFilter.none,
    );
    expect(scanned, isNotNull);
    expect(isMostlyRed(img.decodeImage(scanned!.bytes)!), isTrue);
  });
}
