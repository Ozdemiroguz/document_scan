import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../types/document_corners.dart';
import '../types/scan_filter.dart';
import '../types/scan_input.dart';
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
  }) async {
    final source = await _decodeToImage(input);
    if (source == null) return null;

    final warped = _perspectiveWarp(source, corners);
    final filtered = _applyFilter(warped, filter);
    final png = img.encodePng(filtered);

    return ScannedDocument(
      bytes: Uint8List.fromList(png),
      width: filtered.width,
      height: filtered.height,
    );
  }

  /// Applies a [filter] to an already-cropped document image, without warping.
  /// Useful for re-filtering a scan the user already cropped.
  Future<ScannedDocument?> applyFilter(
    ScanInput input,
    ScanFilter filter,
  ) async {
    final source = await _decodeToImage(input);
    if (source == null) return null;
    final filtered = _applyFilter(source, filter);
    final png = img.encodePng(filtered);
    return ScannedDocument(
      bytes: Uint8List.fromList(png),
      width: filtered.width,
      height: filtered.height,
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
    }
  }
}
