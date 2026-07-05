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
  });

  /// Top-left corner, normalized 0..1.
  final ScanPoint topLeft;

  /// Top-right corner, normalized 0..1.
  final ScanPoint topRight;

  /// Bottom-right corner, normalized 0..1.
  final ScanPoint bottomRight;

  /// Bottom-left corner, normalized 0..1.
  final ScanPoint bottomLeft;

  /// Builds ordered corners from four points in ANY order.
  ///
  /// Uses the standard sum/diff extremes: the point with the smallest x+y is
  /// the top-left, the largest x+y is the bottom-right; the smallest y−x is the
  /// top-right, the largest y−x is the bottom-left. This is stable regardless of
  /// which engine produced the points.
  factory DocumentCorners.fromUnordered(List<ScanPoint> points) {
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

    return DocumentCorners(
      topLeft: pick((p) => p.x + p.y, max: false),
      bottomRight: pick((p) => p.x + p.y, max: true),
      topRight: pick((p) => p.y - p.x, max: false),
      bottomLeft: pick((p) => p.y - p.x, max: true),
    );
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
  String toString() =>
      'DocumentCorners(TL:$topLeft TR:$topRight BR:$bottomRight BL:$bottomLeft)';
}
