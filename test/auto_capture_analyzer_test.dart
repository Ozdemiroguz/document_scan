import 'dart:async';

import 'package:document_scan/document_scan.dart';
import 'package:flutter_test/flutter_test.dart';

/// A steady, high-confidence full-ish document quad.
DocumentCorners goodDoc({double confidence = 0.9, double shift = 0}) {
  return DocumentCorners.fromUnordered([
    (x: 0.10 + shift, y: 0.10 + shift),
    (x: 0.90 + shift, y: 0.10 + shift),
    (x: 0.90 + shift, y: 0.90 + shift),
    (x: 0.10 + shift, y: 0.90 + shift),
  ], confidence: confidence);
}

void main() {
  group('qualification gating', () {
    test('null detection -> searching, resets steadiness', () {
      final a = AutoCaptureAnalyzer(requiredSteadyFrames: 3);
      a.add(goodDoc());
      final s = a.add(null);
      expect(s.status, AutoCaptureStatus.searching);
      expect(s.steadyFrames, 0);
    });

    test('low confidence -> detecting, never ready', () {
      final a = AutoCaptureAnalyzer(requiredSteadyFrames: 2, minConfidence: 0.6);
      var last = AutoCaptureStatus.searching;
      for (var i = 0; i < 5; i++) {
        last = a.add(goodDoc(confidence: 0.3)).status;
      }
      expect(last, AutoCaptureStatus.detecting);
    });

    test('too-small document -> detecting, never ready', () {
      final a = AutoCaptureAnalyzer(requiredSteadyFrames: 2, minArea: 0.15);
      final tiny = DocumentCorners.fromUnordered([
        (x: 0.45, y: 0.45),
        (x: 0.55, y: 0.45),
        (x: 0.55, y: 0.55),
        (x: 0.45, y: 0.55),
      ], confidence: 0.9);
      var ready = false;
      for (var i = 0; i < 6; i++) {
        if (a.add(tiny).shouldCapture) ready = true;
      }
      expect(ready, isFalse);
    });
  });

  group('steadiness + firing', () {
    test('fires ready after requiredSteadyFrames of a steady document', () {
      final a = AutoCaptureAnalyzer(requiredSteadyFrames: 4, maxJitter: 0.02);
      final states = [for (var i = 0; i < 4; i++) a.add(goodDoc())];

      // First three accumulate; the fourth fires.
      expect(states[0].status, AutoCaptureStatus.detecting);
      expect(states[2].status, AutoCaptureStatus.detecting);
      expect(states[3].status, AutoCaptureStatus.ready);
      expect(states[3].shouldCapture, isTrue);
      expect(states[3].steadyFrames, 4);
    });

    test('fires only once per hold (latched)', () {
      final a = AutoCaptureAnalyzer(requiredSteadyFrames: 3);
      var readyCount = 0;
      for (var i = 0; i < 10; i++) {
        if (a.add(goodDoc()).shouldCapture) readyCount++;
      }
      expect(readyCount, 1);
    });

    test('movement past maxJitter restarts the steady count', () {
      final a = AutoCaptureAnalyzer(requiredSteadyFrames: 3, maxJitter: 0.02);
      a.add(goodDoc()); // steady 1
      a.add(goodDoc()); // steady 2
      // Big jump — jitter well above 0.02 — resets to 1.
      final moved = a.add(goodDoc(shift: 0.1));
      expect(moved.steadyFrames, 1);
      expect(moved.status, AutoCaptureStatus.detecting);
    });

    test('re-arms after the document leaves and returns', () {
      final a = AutoCaptureAnalyzer(requiredSteadyFrames: 2);
      // First hold fires.
      a.add(goodDoc());
      expect(a.add(goodDoc()).shouldCapture, isTrue);
      // Document leaves.
      a.add(null);
      // New hold fires again.
      a.add(goodDoc());
      expect(a.add(goodDoc()).shouldCapture, isTrue);
    });

    test('reset() clears accumulated steadiness', () {
      final a = AutoCaptureAnalyzer(requiredSteadyFrames: 3);
      a.add(goodDoc());
      a.add(goodDoc());
      a.reset();
      final s = a.add(goodDoc());
      expect(s.steadyFrames, 1); // counting started over
    });
  });

  group('bind() stream', () {
    test('maps a detection stream to state and fires ready', () async {
      final a = AutoCaptureAnalyzer(requiredSteadyFrames: 3);
      final input = Stream<DocumentCorners?>.fromIterable([
        null,
        goodDoc(),
        goodDoc(),
        goodDoc(),
      ]);
      final states = await a.bind(input).toList();
      expect(states.first.status, AutoCaptureStatus.searching);
      expect(states.last.shouldCapture, isTrue);
    });
  });

  group('addEvent() / bindEvents() — DetectionEvent bridge', () {
    test('DocumentDetected advances toward ready just like add(corners)', () {
      final a = AutoCaptureAnalyzer(requiredSteadyFrames: 2);
      a.addEvent(DocumentDetected(goodDoc()));
      final s = a.addEvent(DocumentDetected(goodDoc()));
      expect(s.shouldCapture, isTrue);
    });

    test('FrameDropped holds state instead of resetting the countdown', () {
      final a = AutoCaptureAnalyzer(requiredSteadyFrames: 3);
      a.addEvent(DocumentDetected(goodDoc()));
      final held = a.addEvent(const FrameDropped());
      // A dropped frame must NOT wipe the accumulated steadiness.
      expect(held.steadyFrames, 1);
      // ...and the next good frame keeps counting up rather than restarting.
      final next = a.addEvent(DocumentDetected(goodDoc()));
      expect(next.steadyFrames, 2);
    });

    test('NoDocument and DetectionError reset like a null frame', () {
      final a = AutoCaptureAnalyzer(requiredSteadyFrames: 3);
      a.addEvent(DocumentDetected(goodDoc()));
      final gone = a.addEvent(const NoDocument());
      expect(gone.steadyFrames, 0);
      expect(gone.status, AutoCaptureStatus.searching);

      a.addEvent(DocumentDetected(goodDoc()));
      final errored = a.addEvent(DetectionError(Exception('x')));
      expect(errored.steadyFrames, 0);
    });

    test('bindEvents pipes a detectStream-shaped stream to ready', () async {
      final a = AutoCaptureAnalyzer(requiredSteadyFrames: 2);
      final events = Stream<DetectionEvent>.fromIterable([
        const NoDocument(),
        const FrameDropped(),
        DocumentDetected(goodDoc()),
        DocumentDetected(goodDoc()),
      ]);
      final states = await a.bindEvents(events).toList();
      expect(states.last.shouldCapture, isTrue);
    });
  });

  group('AutoCaptureState value equality', () {
    test('equal states compare equal', () {
      const a = AutoCaptureState(
        status: AutoCaptureStatus.detecting,
        steadyFrames: 2,
      );
      const b = AutoCaptureState(
        status: AutoCaptureStatus.detecting,
        steadyFrames: 2,
      );
      const c = AutoCaptureState(
        status: AutoCaptureStatus.ready,
        steadyFrames: 2,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });
  });
}
