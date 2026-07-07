import 'dart:math' as math;

/// A single 2D point in normalized image space (0..1), origin top-left.
typedef ScanPoint = ({double x, double y});

/// The four corners of a detected document, always ordered
/// top-left → top-right → bottom-right → bottom-left.
///
/// Coordinates are normalized to 0..1 relative to the image the document was
/// found in, so they are independent of pixel size and easy to map onto any
/// preview or canvas.
///
/// The ordering is derived geometrically (see [fromUnordered]) rather than
/// trusting the detection engine's vertex order — different native engines
/// (Vision, OpenCV, …) return corners in different, sometimes inconsistent
/// orders, so the package normalizes them here.
class DocumentCorners {
  const DocumentCorners({
    required this.topLeft,
    required this.topRight,
    required this.bottomRight,
    required this.bottomLeft,
    this.confidence,
  });

  /// Top-left corner, normalized 0..1.
  final ScanPoint topLeft;

  /// Top-right corner, normalized 0..1.
  final ScanPoint topRight;

  /// Bottom-right corner, normalized 0..1.
  final ScanPoint bottomRight;

  /// Bottom-left corner, normalized 0..1.
  final ScanPoint bottomLeft;

  /// How likely this quad is an actual document, in 0..1 (higher is more
  /// confident), or `null` when no score is available.
  ///
  /// The two platforms derive this differently, so treat it as a relative
  /// ranking signal rather than a calibrated probability:
  /// - **iOS**: the engine's own value ([VNRectangleObservation.confidence]).
  /// - **Android**: OpenCV has no probability, so this is a geometric heuristic
  ///   from the quad's convexity, area and aspect ratio.
  ///
  /// Use it to gate capture or route a weak detection to manual adjustment (see
  /// the auto-capture analyzer), not as a cross-platform absolute.
  final double? confidence;

  /// Builds ordered corners from four points in ANY order.
  ///
  /// Primary method — the standard sum/diff extremes: smallest x+y is top-left,
  /// largest x+y is bottom-right; smallest y−x is top-right, largest y−x is
  /// bottom-left. This is fast and unambiguous for near-upright documents.
  ///
  /// But it has a known failure mode: on a strongly-rotated quad (≳45°, e.g. a
  /// diamond) two roles can resolve to the SAME physical point — the smallest
  /// x+y and the smallest y−x collapse — yielding a degenerate quad with a
  /// duplicated corner, which warps to garbage. When that happens we fall back
  /// to an angular sort about the centroid, which always returns four distinct
  /// corners for any (convex) input. The common case keeps the exact prior
  /// behaviour; only the degenerate case is rescued.
  factory DocumentCorners.fromUnordered(
    List<ScanPoint> points, {
    double? confidence,
  }) {
    assert(points.length == 4, 'Exactly four points are required.');
    ScanPoint pick(double Function(ScanPoint) key, {required bool max}) {
      var best = points.first;
      var bestVal = key(best);
      for (final p in points.skip(1)) {
        final v = key(p);
        if (max ? v > bestVal : v < bestVal) {
          best = p;
          bestVal = v;
        }
      }
      return best;
    }

    final tl = pick((p) => p.x + p.y, max: false);
    final br = pick((p) => p.x + p.y, max: true);
    final tr = pick((p) => p.y - p.x, max: false);
    final bl = pick((p) => p.y - p.x, max: true);

    // Degenerate if any two roles picked the same point (all four must be
    // distinct for a valid quad). Fall back to the angular sort.
    final distinct = <ScanPoint>{tl, tr, br, bl};
    if (distinct.length < 4) {
      return _orderByAngle(points, confidence: confidence);
    }

    return DocumentCorners(
      topLeft: tl,
      bottomRight: br,
      topRight: tr,
      bottomLeft: bl,
      confidence: confidence,
    );
  }

  /// Orders four points TL/TR/BR/BL by their angle about the centroid — robust
  /// for any convex quad, including diamonds the sum/diff method collapses.
  ///
  /// Sorts the points clockwise starting from the top, then rotates the ring so
  /// it begins at the top-left (the top-most point, ties broken to the left).
  static DocumentCorners _orderByAngle(
    List<ScanPoint> points, {
    double? confidence,
  }) {
    final cx = points.map((p) => p.x).reduce((a, b) => a + b) / 4;
    final cy = points.map((p) => p.y).reduce((a, b) => a + b) / 4;

    // Clockwise order in image space (y grows downward): sort by atan2 ascending.
    final ring = [...points]
      ..sort((a, b) =>
          math.atan2(a.y - cy, a.x - cx).compareTo(
            math.atan2(b.y - cy, b.x - cx)));

    // Find the top-left anchor: smallest x+y among the four, then rotate the
    // ring so it starts there and continues clockwise → TL, TR, BR, BL.
    var start = 0;
    var bestKey = double.infinity;
    for (var i = 0; i < 4; i++) {
      final key = ring[i].x + ring[i].y;
      if (key < bestKey) {
        bestKey = key;
        start = i;
      }
    }

    return DocumentCorners(
      topLeft: ring[start],
      topRight: ring[(start + 1) % 4],
      bottomRight: ring[(start + 2) % 4],
      bottomLeft: ring[(start + 3) % 4],
      confidence: confidence,
    );
  }

  /// A copy of these corners with fields replaced. Handy after a manual corner
  /// adjustment (new points) or once a [confidence] has been derived.
  DocumentCorners copyWith({
    ScanPoint? topLeft,
    ScanPoint? topRight,
    ScanPoint? bottomRight,
    ScanPoint? bottomLeft,
    double? confidence,
  }) {
    return DocumentCorners(
      topLeft: topLeft ?? this.topLeft,
      topRight: topRight ?? this.topRight,
      bottomRight: bottomRight ?? this.bottomRight,
      bottomLeft: bottomLeft ?? this.bottomLeft,
      confidence: confidence ?? this.confidence,
    );
  }

  /// A geometric confidence heuristic in 0..1 for engines that don't provide a
  /// probability (e.g. OpenCV on Android).
  ///
  /// Combines three cheap sanity signals: the quad must be convex, cover a
  /// plausible fraction of the frame (neither a speck nor the whole image), and
  /// have a document-like aspect ratio. Returns a blended score — not a
  /// calibrated probability, just a relative "does this look like a document"
  /// ranking, honestly distinct from a native engine's own value.
  double geometricConfidence() {
    if (!isConvex) return 0;

    // Area: reward mid-range coverage, penalize tiny specks and full-frame
    // false positives. Peaks around 15%–85% of the frame.
    final a = area;
    final areaScore = (a < 0.02 || a > 0.98)
        ? 0.0
        : (a >= 0.15 && a <= 0.85)
            ? 1.0
            : 0.6;

    // Aspect ratio from the bounding edges: documents are rectangular-ish, not
    // extreme slivers. Score falls off past ~4:1.
    final pts = toList();
    double edge(int i, int j) {
      final p = pts[i], q = pts[j];
      return math.sqrt(math.pow(p.x - q.x, 2) + math.pow(p.y - q.y, 2));
    }

    final widthAvg = (edge(0, 1) + edge(3, 2)) / 2;
    final heightAvg = (edge(0, 3) + edge(1, 2)) / 2;
    final ratio = widthAvg <= 0 || heightAvg <= 0
        ? 0.0
        : (widthAvg > heightAvg ? widthAvg / heightAvg : heightAvg / widthAvg);
    final aspectScore = ratio <= 0
        ? 0.0
        : ratio <= 4
            ? 1.0
            : (ratio <= 8 ? 0.5 : 0.2);

    // Convex already passed → weight it as a solid base, blend the rest.
    return (0.4 + 0.35 * areaScore + 0.25 * aspectScore).clamp(0.0, 1.0);
  }

  /// Corners in draw order: TL, TR, BR, BL.
  List<ScanPoint> toList() => [topLeft, topRight, bottomRight, bottomLeft];

  /// Approximate area of the quad in normalized units (0..1), via the shoelace
  /// formula. Useful for filtering (e.g. rejecting a near-fullscreen frame).
  double get area {
    final pts = toList();
    var sum = 0.0;
    for (var i = 0; i < 4; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % 4];
      sum += a.x * b.y - b.x * a.y;
    }
    return sum.abs() / 2;
  }

  /// Whether the quad is convex — a sanity check for a real document outline.
  bool get isConvex {
    final pts = toList();
    var sign = 0;
    for (var i = 0; i < 4; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % 4];
      final c = pts[(i + 2) % 4];
      final cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
      if (cross != 0) {
        final s = cross > 0 ? 1 : -1;
        if (sign == 0) {
          sign = s;
        } else if (s != sign) {
          return false;
        }
      }
    }
    return true;
  }

  /// Scales the normalized corners to pixel coordinates for an image of
  /// [width] × [height].
  List<({double x, double y})> toPixels(int width, int height) => [
    (x: topLeft.x * width, y: topLeft.y * height),
    (x: topRight.x * width, y: topRight.y * height),
    (x: bottomRight.x * width, y: bottomRight.y * height),
    (x: bottomLeft.x * width, y: bottomLeft.y * height),
  ];

  /// The longest edge length in normalized units — handy for a rough size gate.
  double get longestEdge {
    final pts = toList();
    var longest = 0.0;
    for (var i = 0; i < 4; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % 4];
      final d = math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));
      if (d > longest) longest = d;
    }
    return longest;
  }

  @override
  bool operator ==(Object other) =>
      other is DocumentCorners &&
      other.topLeft == topLeft &&
      other.topRight == topRight &&
      other.bottomRight == bottomRight &&
      other.bottomLeft == bottomLeft &&
      other.confidence == confidence;

  @override
  int get hashCode =>
      Object.hash(topLeft, topRight, bottomRight, bottomLeft, confidence);

  @override
  String toString() =>
      'DocumentCorners(TL:$topLeft TR:$topRight BR:$bottomRight BL:$bottomLeft'
      '${confidence == null ? '' : ', conf:${confidence!.toStringAsFixed(2)}'})';
}
