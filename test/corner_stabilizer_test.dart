import 'package:document_scan/document_scan.dart';
import 'package:flutter_test/flutter_test.dart';

DocumentCorners _square(double offset) => DocumentCorners(
      topLeft: (x: 0.1 + offset, y: 0.1 + offset),
      topRight: (x: 0.9 + offset, y: 0.1 + offset),
      bottomRight: (x: 0.9 + offset, y: 0.9 + offset),
      bottomLeft: (x: 0.1 + offset, y: 0.9 + offset),
    );

void main() {
  group('CornerStabilizer', () {
    test('first frame passes through unchanged (no prior state)', () {
      final s = CornerStabilizer();
      final first = _square(0);
      expect(s.add(first), first);
    });

    test('smooths a small jitter toward the new corner by `smoothing`', () {
      final s = CornerStabilizer(smoothing: 0.5, resetDistance: 0.2);
      s.add(_square(0)); // seed at 0
      // A tiny 0.02 shift (well under resetDistance) → EMA moves halfway: 0.01.
      final out = s.add(_square(0.02))!;
      expect(out.topLeft.x, closeTo(0.11, 1e-9)); // 0.1 + 0.5*0.02
      expect(out.topLeft.y, closeTo(0.11, 1e-9));
    });

    test('smoothing: 1.0 disables smoothing (always the raw corner)', () {
      final s = CornerStabilizer(smoothing: 1.0);
      s.add(_square(0));
      final raw = _square(0.03);
      expect(s.add(raw), raw);
    });

    test('a jump larger than resetDistance snaps instead of sliding', () {
      final s = CornerStabilizer(smoothing: 0.5, resetDistance: 0.2);
      s.add(_square(0));
      // 0.3 shift on every corner > resetDistance 0.2 → snap to the new pos.
      final jumped = _square(0.3);
      expect(s.add(jumped), jumped);
    });

    test('null (no document) resets, so the next document does not slide in',
        () {
      final s = CornerStabilizer(smoothing: 0.5, resetDistance: 0.2);
      s.add(_square(0));
      expect(s.add(null), isNull); // document left
      final reappear = _square(0.5);
      // Fresh start → passes through, not averaged against the pre-gap position.
      expect(s.add(reappear), reappear);
    });

    test('carries the latest confidence, not an averaged one', () {
      final s = CornerStabilizer(smoothing: 0.5, resetDistance: 0.2);
      s.add(_square(0).copyWith(confidence: 0.2));
      final out = s.add(_square(0.02).copyWith(confidence: 0.9))!;
      expect(out.confidence, 0.9);
    });

    test('reset() clears state; next add passes through', () {
      final s = CornerStabilizer();
      s.add(_square(0));
      s.reset();
      final next = _square(0.02);
      expect(s.add(next), next);
    });

    test('repeated identical frames converge to that exact position', () {
      final s = CornerStabilizer(smoothing: 0.5);
      final target = _square(0.02);
      s.add(_square(0));
      DocumentCorners? out;
      for (var i = 0; i < 40; i++) {
        out = s.add(target);
      }
      expect(out!.topLeft.x, closeTo(target.topLeft.x, 1e-6));
      expect(out.topLeft.y, closeTo(target.topLeft.y, 1e-6));
    });
  });
}
