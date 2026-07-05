import 'package:document_scan/document_scan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DocumentCorners.fromUnordered', () {
    test('orders arbitrary points into TL/TR/BR/BL', () {
      // Feed the four corners of a unit square in a shuffled order.
      final c = DocumentCorners.fromUnordered([
        (x: 0.9, y: 0.9), // BR
        (x: 0.1, y: 0.1), // TL
        (x: 0.9, y: 0.1), // TR
        (x: 0.1, y: 0.9), // BL
      ]);
      expect(c.topLeft, (x: 0.1, y: 0.1));
      expect(c.topRight, (x: 0.9, y: 0.1));
      expect(c.bottomRight, (x: 0.9, y: 0.9));
      expect(c.bottomLeft, (x: 0.1, y: 0.9));
    });

    test('handles a perspective-skewed quad', () {
      // A realistic slightly-tilted document (not a symmetric diamond, so the
      // sum/diff extremes are unambiguous).
      final c = DocumentCorners.fromUnordered([
        (x: 0.85, y: 0.80), // BR
        (x: 0.15, y: 0.10), // TL
        (x: 0.90, y: 0.15), // TR
        (x: 0.10, y: 0.85), // BL
      ]);
      expect(c.topLeft, (x: 0.15, y: 0.10)); // smallest x+y
      expect(c.bottomRight, (x: 0.85, y: 0.80)); // largest x+y
      expect(c.topRight, (x: 0.90, y: 0.15)); // smallest y-x
      expect(c.bottomLeft, (x: 0.10, y: 0.85)); // largest y-x
    });
  });

  group('geometry helpers', () {
    final square = DocumentCorners.fromUnordered([
      (x: 0.0, y: 0.0),
      (x: 1.0, y: 0.0),
      (x: 1.0, y: 1.0),
      (x: 0.0, y: 1.0),
    ]);

    test('area of the full unit square is ~1', () {
      expect(square.area, closeTo(1.0, 1e-9));
    });

    test('a proper rectangle is convex', () {
      expect(square.isConvex, isTrue);
    });

    test('toPixels scales to image size', () {
      final px = square.toPixels(100, 200);
      expect(px[2], (x: 100.0, y: 200.0)); // BR
    });

    test('longestEdge of the unit square is 1', () {
      expect(square.longestEdge, closeTo(1.0, 1e-9));
    });
  });
}
