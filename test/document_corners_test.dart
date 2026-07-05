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

  group('confidence', () {
    test('fromUnordered carries an explicit confidence through', () {
      final c = DocumentCorners.fromUnordered([
        (x: 0.1, y: 0.1),
        (x: 0.9, y: 0.1),
        (x: 0.9, y: 0.9),
        (x: 0.1, y: 0.9),
      ], confidence: 0.77);
      expect(c.confidence, 0.77);
    });

    test('copyWith replaces confidence, keeps corners', () {
      const c = DocumentCorners(
        topLeft: (x: 0.0, y: 0.0),
        topRight: (x: 1.0, y: 0.0),
        bottomRight: (x: 1.0, y: 1.0),
        bottomLeft: (x: 0.0, y: 1.0),
      );
      final scored = c.copyWith(confidence: 0.5);
      expect(scored.confidence, 0.5);
      expect(scored.topRight, (x: 1.0, y: 0.0));
    });

    test('geometricConfidence rewards a mid-size convex rectangle', () {
      // A clean, centered document quad (~64% of the frame).
      final good = DocumentCorners.fromUnordered([
        (x: 0.1, y: 0.1),
        (x: 0.9, y: 0.1),
        (x: 0.9, y: 0.9),
        (x: 0.1, y: 0.9),
      ]);
      expect(good.geometricConfidence(), greaterThan(0.8));
    });

    test('geometricConfidence is 0 for a non-convex quad', () {
      // A self-intersecting (bowtie) quad after ordering stays non-convex.
      final bowtie = DocumentCorners(
        topLeft: (x: 0.1, y: 0.1),
        topRight: (x: 0.9, y: 0.9),
        bottomRight: (x: 0.9, y: 0.1),
        bottomLeft: (x: 0.1, y: 0.9),
      );
      expect(bowtie.isConvex, isFalse);
      expect(bowtie.geometricConfidence(), 0);
    });

    test('geometricConfidence penalizes a near-fullscreen quad', () {
      final full = DocumentCorners.fromUnordered([
        (x: 0.0, y: 0.0),
        (x: 1.0, y: 0.0),
        (x: 1.0, y: 1.0),
        (x: 0.0, y: 1.0),
      ]);
      final mid = DocumentCorners.fromUnordered([
        (x: 0.1, y: 0.1),
        (x: 0.9, y: 0.1),
        (x: 0.9, y: 0.9),
        (x: 0.1, y: 0.9),
      ]);
      // area ~1.0 (full frame, likely a false positive) scores below a
      // comfortably-framed document.
      expect(full.geometricConfidence(), lessThan(mid.geometricConfidence()));
    });
  });
}
