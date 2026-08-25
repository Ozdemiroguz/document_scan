import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../types/document_corners.dart';
import '../types/scan_filter.dart';
import '../types/scan_input.dart';
import '../types/scan_output_format.dart';
import '../types/scanned_document.dart';

/// Turns a document image + its [DocumentCorners] into a clean, upright scan:
/// perspective-corrects (warps) the quad to a rectangle, then optionally
/// applies a [ScanFilter]. Pure Dart (via the `image` package) — no native
/// dependency and no platform channel, so unlike [DocumentDetector] it needs
/// nothing from the host platform. (`background: true` is the one exception: it
/// uses `Isolate.run`, which has no web implementation.)
///
/// It is independent of [DocumentDetector]: give it corners from anywhere (the
/// detector, a user's manual adjustment, your own algorithm).
class DocumentProcessor {
  const DocumentProcessor();

  /// The default cap on the warped output's long side, in pixels. A document
  /// scan is legible and OCR-ready well below full-sensor resolution, so
  /// warping a near-full-frame 12 MP photo at its native ~4000px would burn
  /// CPU and memory (the warp is a per-output-pixel bilinear sample in Dart)
  /// for no visible gain. Capping at 2000px keeps the common case fast; pass a
  /// different `maxDimension` (or `null`) to [crop] to change or lift it.
  static const defaultMaxDimension = 2000;

  /// Perspective-corrects the document bounded by [corners] out of [input] and
  /// returns it as an upright rectangle. [filter] post-processes the result.
  ///
  /// Note: [filter] defaults to [ScanFilter.none] here (this is the raw
  /// primitive — it does exactly what you ask). The high-level
  /// [DocumentScanner.scan] instead defaults to [ScanFilter.enhance] for a
  /// clean "scanned" look out of the box, so if you drop from the façade to
  /// this method to reproduce the same result, pass `filter: ScanFilter.enhance`.
  ///
  /// [corners] are normalized 0..1 relative to [input]'s image. The output
  /// resolution matches the document's real edge lengths, so a near-square card
  /// and a tall page both come out proportioned correctly — but the long side is
  /// capped at [maxDimension] (default [defaultMaxDimension], pass `null` to
  /// warp at full resolution) so a near-full-frame high-megapixel photo doesn't
  /// produce a needlessly huge, slow warp. The aspect ratio is preserved.
  ///
  /// The warp + filter + encode is pure-Dart CPU work — on a full-frame photo it
  /// takes long enough to jank the UI. Pass [background] `true` to run it on a
  /// background isolate (via `Isolate.run`) so the caller's thread stays
  /// responsive; the default `false` runs it on the current isolate (right when
  /// you're already on a background isolate, or the image is small). This is a
  /// primitive, so it defaults to foreground — the [DocumentScanner.scan] façade
  /// defaults `background` to `true` for you. Note that `Isolate.run` *copies*
  /// what it captures, so a [BytesScanInput] pays a full duplicate of its buffer
  /// during the hop; a [FileScanInput] carries only a path and is cheaper.
  ///
  /// Returns `null` if the input image can't be decoded.
  Future<ScannedDocument?> crop(
    ScanInput input,
    DocumentCorners corners, {
    ScanFilter filter = ScanFilter.none,
    ScanOutputFormat output = ScanOutputFormat.png,
    int? maxDimension = defaultMaxDimension,
    bool background = false,
  }) {
    assert(
      maxDimension == null || maxDimension >= 1,
      'maxDimension must be null (uncapped) or >= 1.',
    );
    // Everything captured is sendable (value types + a path/bytes), and the
    // processor is reconstructed inside the isolate rather than captured, so the
    // whole job runs cleanly on a spawned isolate.
    if (background) {
      return Isolate.run(
        () => const DocumentProcessor()._cropSync(
          input,
          corners,
          filter,
          output,
          maxDimension,
        ),
      );
    }
    return _cropSync(input, corners, filter, output, maxDimension);
  }

  Future<ScannedDocument?> _cropSync(
    ScanInput input,
    DocumentCorners corners,
    ScanFilter filter,
    ScanOutputFormat output,
    int? maxDimension,
  ) async {
    final source = await _decodeToImage(input);
    if (source == null) return null;

    final warped = _perspectiveWarp(
      source,
      corners,
      maxDimension: maxDimension,
    );
    final filtered = _applyFilter(warped, filter);
    return _encode(filtered, output);
  }

  /// Applies a [filter] to an already-cropped document image, without warping.
  /// Useful for re-filtering a scan the user already cropped.
  ///
  /// [background] mirrors [crop]: `true` runs the decode + filter + encode on a
  /// background isolate so the UI stays responsive; the default `false` runs it
  /// on the current isolate.
  Future<ScannedDocument?> applyFilter(
    ScanInput input,
    ScanFilter filter, {
    ScanOutputFormat output = ScanOutputFormat.png,
    bool background = false,
  }) {
    if (background) {
      return Isolate.run(
        () => const DocumentProcessor()._applyFilterSync(input, filter, output),
      );
    }
    return _applyFilterSync(input, filter, output);
  }

  Future<ScannedDocument?> _applyFilterSync(
    ScanInput input,
    ScanFilter filter,
    ScanOutputFormat output,
  ) async {
    final source = await _decodeToImage(input);
    if (source == null) return null;
    final filtered = _applyFilter(source, filter);
    return _encode(filtered, output);
  }

  // --- encode output ---

  Future<ScannedDocument> _encode(
    img.Image image,
    ScanOutputFormat output,
  ) async {
    final bytes = switch (output.codec) {
      ScanImageCodec.png => img.encodePng(image),
      ScanImageCodec.jpeg => img.encodeJpg(image, quality: output.quality),
      ScanImageCodec.pdf => await _encodePdf(image),
    };
    return ScannedDocument(
      bytes: Uint8List.fromList(bytes),
      width: image.width,
      height: image.height,
    );
  }

  /// Wraps the scan in a single-page A4 PDF (fit inside the page). PNG-encoded
  /// internally so the PDF embeds a lossless image.
  Future<List<int>> _encodePdf(img.Image image) async {
    final png = Uint8List.fromList(img.encodePng(image));
    return _pdfFromEncodedPages([png]);
  }

  /// Builds a PDF with one A4 page per entry in [encodedImages]. Each entry is
  /// already-encoded PNG/JPEG bytes, embedded as-is (no re-encode).
  Future<List<int>> _pdfFromEncodedPages(List<Uint8List> encodedImages) async {
    final doc = pw.Document();
    for (final bytes in encodedImages) {
      final pdfImage = pw.MemoryImage(bytes);
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          build: (_) =>
              pw.Center(child: pw.Image(pdfImage, fit: pw.BoxFit.contain)),
        ),
      );
    }
    return doc.save();
  }

  /// Combines several scanned pages into one multi-page PDF — one A4 page per
  /// scan, in order. Pass the pages from a [ScanSession] (or any list of
  /// [ScannedDocument]s) you've collected.
  ///
  /// Each page's [ScannedDocument.bytes] is embedded directly, so give it image
  /// scans (`ScanOutputFormat.png` / `.jpeg`) — not PDFs. Returns null if
  /// [pages] is empty.
  ///
  /// This is the multi-page counterpart to `output: ScanOutputFormat.pdf`, which
  /// produces a single-page PDF from one crop.
  Future<ScannedDocument?> pagesToPdf(List<ScannedDocument> pages) async {
    if (pages.isEmpty) return null;
    final pdfBytes = await _pdfFromEncodedPages([
      for (final p in pages) p.bytes,
    ]);
    // A PDF has no single pixel size; report the first page's dimensions so the
    // ScannedDocument stays well-formed.
    return ScannedDocument(
      bytes: Uint8List.fromList(pdfBytes),
      width: pages.first.width,
      height: pages.first.height,
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
          // ORIENTATION CONTRACT: corners are in EXIF-*oriented* (upright)
          // space — Apple Vision applies the file's orientation, and the
          // Android native side bakes it before detecting. The crop must sample
          // pixels in that same space or an iPhone portrait photo (EXIF 6/8)
          // warps 90° off. `image`'s JPEG/PNG decoders already apply EXIF
          // orientation on decode and clear the tag (see image package
          // _jpeg_quantize: it rotates and nulls imageIfd.orientation), so
          // `decodeImageFile` returns upright pixels — aligned with the
          // corners. A `bakeOrientation` here would be a redundant no-op. This
          // invariant is locked by document_processor_orientation_test.dart; if
          // a future decoder stops auto-applying EXIF, that test fails and a
          // `bakeOrientation` call belongs right here.
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

  img.Image _perspectiveWarp(
    img.Image src,
    DocumentCorners corners, {
    int? maxDimension,
  }) {
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
    var outW = ((widthTop + widthBottom) / 2).round().clamp(1, w * 2);
    var outH = ((heightLeft + heightRight) / 2).round().clamp(1, h * 2);

    // Cap the long side at maxDimension, scaling both axes together so the
    // document's aspect ratio is preserved (a tall page stays tall).
    if (maxDimension != null) {
      final longSide = math.max(outW, outH);
      if (longSide > maxDimension) {
        final scale = maxDimension / longSide;
        outW = (outW * scale).round().clamp(1, outW);
        outH = (outH * scale).round().clamp(1, outH);
      }
    }

    final dst = img.Image(width: outW, height: outH, numChannels: 3);

    // Inverse map: for each output pixel, find where it came from in the source
    // and sample there. The correct mapping for a flat document photographed at
    // an angle is a PROJECTIVE one (a homography) — a bilinear blend of the four
    // corners lands the corners exactly but gets everything between them wrong,
    // because it has no perspective division: the far edge of a tilted page is
    // foreshortened, so equal steps across the document are NOT equal steps
    // across the photo. See _unitSquareToQuad.
    final hm = _unitSquareToQuad(tl, tr, br, bl);

    // Guard the divisor: a degenerate quad (a collapsed edge, or a very wide/thin
    // region that the size cap rounds to a 1px axis) gives outW/outH == 1, and
    // `x / (outW - 1)` would be 0/0 = NaN → NaN.toInt() throws inside the sampler.
    // A single row/column maps to parameter 0, so clamp the divisor to at least 1.
    final duW = outW > 1 ? outW - 1 : 1;
    final duH = outH > 1 ? outH - 1 : 1;
    final maxX = (w - 1).toDouble();
    final maxY = (h - 1).toDouble();

    // Both branches hoist everything that only depends on the row, so the inner
    // loop is a couple of multiplies plus (projective) one reciprocal. The
    // branch itself is outside the loops — it never changes mid-warp.
    if (hm != null) {
      for (var y = 0; y < outH; y++) {
        final v = y / duH;
        final wRow = hm.h * v + 1; // the denominator's row-constant part
        final xRow = hm.b * v + hm.c;
        final yRow = hm.e * v + hm.f;
        for (var x = 0; x < outW; x++) {
          final u = x / duW;
          final denom = hm.g * u + wRow;
          // denom == 0 is the quad's horizon — only reachable for a non-convex
          // or wildly wrong quad, and it would send the sampler infinities (and
          // NaN.toInt() throws). Collapse the row to the origin instead: a bad
          // quad yields a bad crop, never a crash.
          final inv = denom == 0 ? 0.0 : 1 / denom;
          _sample(
            src,
            dst,
            x,
            y,
            (hm.a * u + xRow) * inv,
            (hm.d * u + yRow) * inv,
            maxX,
            maxY,
          );
        }
      }
    } else {
      // Degenerate quad: no homography exists (three corners collinear, or a
      // collapsed edge). Fall back to the bilinear blend, which is always
      // finite. Per row it reduces to a lerp between the quad's left and right
      // edges at that row.
      for (var y = 0; y < outH; y++) {
        final v = y / duH;
        final lx = tl.x + (bl.x - tl.x) * v;
        final ly = tl.y + (bl.y - tl.y) * v;
        final rx = tr.x + (br.x - tr.x) * v;
        final ry = tr.y + (br.y - tr.y) * v;
        for (var x = 0; x < outW; x++) {
          final u = x / duW;
          _sample(
            src,
            dst,
            x,
            y,
            lx + (rx - lx) * u,
            ly + (ry - ly) * u,
            maxX,
            maxY,
          );
        }
      }
    }
    return dst;
  }

  /// Samples [src] at ([sx], [sy]) — clamped into the image, and treating a
  /// non-finite coordinate as the origin — into [dst] at ([x], [y]).
  static void _sample(
    img.Image src,
    img.Image dst,
    int x,
    int y,
    double sx,
    double sy,
    double maxX,
    double maxY,
  ) {
    dst.setPixel(
      x,
      y,
      src.getPixelInterpolate(
        sx.isFinite ? sx.clamp(0.0, maxX) : 0.0,
        sy.isFinite ? sy.clamp(0.0, maxY) : 0.0,
        interpolation: img.Interpolation.linear,
      ),
    );
  }

  /// The projective transform (homography) taking the unit square's corners
  /// `(0,0) (1,0) (1,1) (0,1)` to [tl], [tr], [br], [bl] in source pixels:
  ///
  /// ```text
  /// sx = (a·u + b·v + c) / (g·u + h·v + 1)
  /// sy = (d·u + e·v + f) / (g·u + h·v + 1)
  /// ```
  ///
  /// The `g`/`h` terms are the perspective part — they are what a bilinear
  /// four-corner blend is missing, and why that blend distorts the interior of a
  /// tilted document even though it pins the corners exactly.
  ///
  /// Closed form (Heckbert, _Fundamentals of Texture Mapping and Image Warping_,
  /// §2.2) rather than an 8×8 solve, so it costs a handful of multiplies once per
  /// crop. Returns `null` for a degenerate quad, where no homography exists.
  static ({
    double a,
    double b,
    double c,
    double d,
    double e,
    double f,
    double g,
    double h,
  })?
  _unitSquareToQuad(
    ({double x, double y}) tl,
    ({double x, double y}) tr,
    ({double x, double y}) br,
    ({double x, double y}) bl,
  ) {
    final dx1 = tr.x - br.x, dx2 = bl.x - br.x, dx3 = tl.x - tr.x + br.x - bl.x;
    final dy1 = tr.y - br.y, dy2 = bl.y - br.y, dy3 = tl.y - tr.y + br.y - bl.y;

    // A parallelogram (opposite edges parallel) has no perspective component —
    // the map is affine and the general formula's denominator would be spurious.
    if (dx3 == 0 && dy3 == 0) {
      return (
        a: tr.x - tl.x,
        b: bl.x - tl.x,
        c: tl.x,
        d: tr.y - tl.y,
        e: bl.y - tl.y,
        f: tl.y,
        g: 0,
        h: 0,
      );
    }

    final den = dx1 * dy2 - dx2 * dy1;
    // den == 0 means two opposite edges are parallel *and* the quad is not a
    // parallelogram — three corners collinear or an edge collapsed to a point.
    // No homography maps the unit square onto that; let the caller fall back.
    if (den == 0 || !den.isFinite) return null;

    final g = (dx3 * dy2 - dx2 * dy3) / den;
    final h = (dx1 * dy3 - dx3 * dy1) / den;
    if (!g.isFinite || !h.isFinite) return null;

    return (
      a: tr.x - tl.x + g * tr.x,
      b: bl.x - tl.x + h * bl.x,
      c: tl.x,
      d: tr.y - tl.y + g * tr.y,
      e: bl.y - tl.y + h * bl.y,
      f: tl.y,
      g: g,
      h: h,
    );
  }

  // --- filters ---

  img.Image _applyFilter(img.Image src, ScanFilter filter) {
    switch (filter) {
      case ScanFilter.none:
        return src;
      case ScanFilter.grayscale:
        return img.grayscale(src);
      case ScanFilter.enhance:
        // Grayscale, boost contrast, then stretch the histogram to the full
        // 0..255 range so gray-ish photographed paper reads as clean white/black.
        final g = img.grayscale(src);
        final c = img.adjustColor(g, contrast: 1.5);
        return img.normalize(c, min: 0, max: 255);
      case ScanFilter.blackWhite:
        return _blackWhite(src);
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

  /// Global-threshold binarization: every pixel becomes ink (black) or paper
  /// (white), with the cut chosen by Otsu's method — the luminance that best
  /// separates the histogram into two classes. One threshold for the whole
  /// image, so it's fast and clean on evenly-lit pages; where the lighting is
  /// uneven a shadowed region drifts to solid black, which is what the per-region
  /// [ScanFilter.magicColor] exists to fix.
  img.Image _blackWhite(img.Image src) {
    final gray = img.grayscale(src);
    final w = gray.width;
    final h = gray.height;

    final lum = Uint8List(w * h);
    final histogram = List<int>.filled(256, 0);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final v = gray.getPixel(x, y).r.toInt();
        lum[y * w + x] = v;
        histogram[v]++;
      }
    }

    final threshold = _otsuThreshold(histogram, w * h);
    final out = img.Image(width: w, height: h, numChannels: 1);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final ink = lum[y * w + x] <= threshold;
        out.setPixelRgb(x, y, ink ? 0 : 255, ink ? 0 : 255, ink ? 0 : 255);
      }
    }
    return out;
  }

  /// Otsu's threshold: the luminance cut that maximizes between-class variance,
  /// i.e. splits the histogram into the two most-separated groups (ink / paper).
  /// Single pass over the 256 bins, so it's independent of the pixel count.
  static int _otsuThreshold(List<int> histogram, int total) {
    if (total == 0) return 127;
    var weightedTotal = 0.0;
    for (var i = 0; i < 256; i++) {
      weightedTotal += i * histogram[i];
    }
    var sumBelow = 0.0;
    var countBelow = 0;
    var bestVariance = -1.0;
    var threshold = 127;
    for (var t = 0; t < 256; t++) {
      countBelow += histogram[t];
      if (countBelow == 0) continue; // nothing at or below t yet
      final countAbove = total - countBelow;
      if (countAbove == 0) break; // t is past the brightest pixel
      sumBelow += t * histogram[t];
      final meanBelow = sumBelow / countBelow;
      final meanAbove = (weightedTotal - sumBelow) / countAbove;
      final diff = meanBelow - meanAbove;
      final variance = countBelow * countAbove * diff * diff;
      if (variance > bestVariance) {
        bestVariance = variance;
        threshold = t;
      }
    }
    return threshold;
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
        final sum =
            integral[y2 * (w + 1) + x2] -
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
