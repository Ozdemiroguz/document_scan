import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../types/document_corners.dart';
import '../types/scan_filter.dart';
import '../types/scan_input.dart';
import '../types/scan_output_format.dart';
import '../types/scanned_document.dart';

/// Turns a document image + its [DocumentCorners] into a clean, upright scan:
/// perspective-corrects (warps) the quad to a rectangle, then optionally
/// applies a [ScanFilter]. Pure Dart (via the `image` package) — no native
/// dependency, so it works anywhere Flutter runs.
///
/// It is independent of [DocumentDetector]: give it corners from anywhere (the
/// detector, a user's manual adjustment, your own algorithm).
class DocumentProcessor {
  const DocumentProcessor();

  /// Perspective-corrects the document bounded by [corners] out of [input] and
  /// returns it as an upright rectangle. [filter] post-processes the result.
  ///
  /// [corners] are normalized 0..1 relative to [input]'s image. The output
  /// resolution matches the document's real edge lengths, so a near-square card
  /// and a tall page both come out proportioned correctly.
  ///
  /// Returns `null` if the input image can't be decoded.
  Future<ScannedDocument?> crop(
    ScanInput input,
    DocumentCorners corners, {
    ScanFilter filter = ScanFilter.none,
    ScanOutputFormat output = ScanOutputFormat.png,
  }) async {
    final source = await _decodeToImage(input);
    if (source == null) return null;

    final warped = _perspectiveWarp(source, corners);
    final filtered = _applyFilter(warped, filter);
    return _encode(filtered, output);
  }

  /// Applies a [filter] to an already-cropped document image, without warping.
  /// Useful for re-filtering a scan the user already cropped.
  Future<ScannedDocument?> applyFilter(
    ScanInput input,
    ScanFilter filter, {
    ScanOutputFormat output = ScanOutputFormat.png,
  }) async {
    final source = await _decodeToImage(input);
    if (source == null) return null;
    final filtered = _applyFilter(source, filter);
    return _encode(filtered, output);
  }

  // --- encode output ---

  ScannedDocument _encode(img.Image image, ScanOutputFormat output) {
    final bytes = switch (output.codec) {
      ScanImageCodec.png => img.encodePng(image),
      ScanImageCodec.jpeg => img.encodeJpg(image, quality: output.quality),
    };
    return ScannedDocument(
      bytes: Uint8List.fromList(bytes),
      width: image.width,
      height: image.height,
    );
  }

  // --- decode ---

  Future<img.Image?> _decodeToImage(ScanInput input) async {
    // Decoding untrusted bytes can throw (some decoders in the `image` package
    // read headers optimistically and range-fault on malformed data), so treat
    // any failure as "undecodable" and return null — matching the documented
    // contract of crop()/applyFilter().
    try {
      switch (input) {
        case FileScanInput(:final path):
          return await img.decodeImageFile(path);
        case BytesScanInput(:final bytes):
          return img.decodeImage(bytes);
        case CameraFrameScanInput():
          // Cropping a raw camera frame is uncommon (you'd normally capture a
          // full-res still first). Not supported here to keep the frame path
          // allocation-free; decode a file/bytes instead.
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  // --- perspective warp ---

  img.Image _perspectiveWarp(img.Image src, DocumentCorners corners) {
    final w = src.width;
    final h = src.height;
    final px = corners.toPixels(w, h);
    final tl = px[0], tr = px[1], br = px[2], bl = px[3];

    // Output size = average of opposite edge lengths, so proportions are kept.
    double dist(({double x, double y}) a, ({double x, double y}) b) {
      final dx = a.x - b.x, dy = a.y - b.y;
      return math.sqrt(dx * dx + dy * dy);
    }

    final widthTop = dist(tl, tr);
    final widthBottom = dist(bl, br);
    final heightLeft = dist(tl, bl);
    final heightRight = dist(tr, br);
    final outW = ((widthTop + widthBottom) / 2).round().clamp(1, w * 2);
    final outH = ((heightLeft + heightRight) / 2).round().clamp(1, h * 2);

    final dst = img.Image(width: outW, height: outH, numChannels: 3);

    // Inverse bilinear map: for each output pixel, find its source via the unit
    // square -> quad mapping and sample. This is the standard four-corner warp.
    for (var y = 0; y < outH; y++) {
      final v = y / (outH - 1);
      for (var x = 0; x < outW; x++) {
        final u = x / (outW - 1);
        // Bilinear interpolation of the four corners.
        final sx =
            (1 - u) * (1 - v) * tl.x +
            u * (1 - v) * tr.x +
            u * v * br.x +
            (1 - u) * v * bl.x;
        final sy =
            (1 - u) * (1 - v) * tl.y +
            u * (1 - v) * tr.y +
            u * v * br.y +
            (1 - u) * v * bl.y;
        final px2 = src.getPixelInterpolate(
          sx,
          sy,
          interpolation: img.Interpolation.linear,
        );
        dst.setPixel(x, y, px2);
      }
    }
    return dst;
  }

  // --- filters ---

  img.Image _applyFilter(img.Image src, ScanFilter filter) {
    switch (filter) {
      case ScanFilter.none:
        return src;
      case ScanFilter.grayscale:
        return img.grayscale(src);
      case ScanFilter.blackWhite:
        // Grayscale then contrast-boost + threshold-ish for a paper look.
        final g = img.grayscale(src);
        return img.adjustColor(g, contrast: 1.6, brightness: 1.05);
      case ScanFilter.sharpen:
        return img.convolution(
          src,
          filter: const [0, -1, 0, -1, 5, -1, 0, -1, 0],
          div: 1,
        );
      case ScanFilter.magicColor:
        return _magicColor(src);
    }
  }

  /// Adaptive-threshold document clean-up (Bradley/Wellner style).
  ///
  /// For each pixel, compare its luminance against the mean luminance of the
  /// surrounding window: pixels sufficiently darker than their local mean become
  /// ink (black), the rest become paper (white). Because the threshold is local
  /// it survives uneven lighting and shadows that wash out a global threshold.
  /// The window mean is computed in O(1) per pixel via an integral image, so
  /// the whole pass is linear in the pixel count.
  img.Image _magicColor(img.Image src) {
    final gray = img.grayscale(src);
    final w = gray.width;
    final h = gray.height;

    // Luminance of each pixel (0..255).
    final lum = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        lum[y * w + x] = gray.getPixel(x, y).r.toInt();
      }
    }

    // Integral image (summed-area table) for O(1) window sums. Width+1 padding
    // avoids bounds checks at the edges.
    final integral = List<int>.filled((w + 1) * (h + 1), 0);
    for (var y = 1; y <= h; y++) {
      var rowSum = 0;
      for (var x = 1; x <= w; x++) {
        rowSum += lum[(y - 1) * w + (x - 1)];
        integral[y * (w + 1) + x] = integral[(y - 1) * (w + 1) + x] + rowSum;
      }
    }

    // Window ~ 1/8 of the smaller side; the classic Bradley threshold subtracts
    // a small percentage so near-mean (paper) pixels round up to white.
    final radius = (math.min(w, h) / 16).clamp(4, 40).toInt();
    const tPercent = 0.85; // ink if pixel < 85% of local mean

    final out = img.Image(width: w, height: h, numChannels: 1);
    for (var y = 0; y < h; y++) {
      final y1 = (y - radius).clamp(0, h);
      final y2 = (y + radius + 1).clamp(0, h);
      for (var x = 0; x < w; x++) {
        final x1 = (x - radius).clamp(0, w);
        final x2 = (x + radius + 1).clamp(0, w);
        final count = (x2 - x1) * (y2 - y1);
        final sum = integral[y2 * (w + 1) + x2] -
            integral[y1 * (w + 1) + x2] -
            integral[y2 * (w + 1) + x1] +
            integral[y1 * (w + 1) + x1];
        final mean = sum / count;
        final v = lum[y * w + x];
        // Ink if the pixel is meaningfully darker than its local mean, OR
        // absolutely very dark (so a large solid ink region — whose own pixels
        // drag the local mean down — still reads as ink, not paper).
        final ink = v < mean * tPercent || v < 60;
        out.setPixelRgb(x, y, ink ? 0 : 255, ink ? 0 : 255, ink ? 0 : 255);
      }
    }
    return out;
  }
}
