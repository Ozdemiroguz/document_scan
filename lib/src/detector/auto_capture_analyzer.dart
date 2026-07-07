import 'dart:async';
import 'dart:math' as math;

import '../types/document_corners.dart';
import 'detection_event.dart';

/// Where the auto-capture state machine currently is.
enum AutoCaptureStatus {
  /// No document in the frame.
  searching,

  /// A document is visible but not yet confident/steady enough to capture.
  detecting,

  /// A good document has been steady across enough frames — capture now.
  ready,
}

/// A snapshot of the auto-capture analyzer's state for one frame.
class AutoCaptureState {
  const AutoCaptureState({
    required this.status,
    this.corners,
    this.steadyFrames = 0,
  });

  /// The current phase.
  final AutoCaptureStatus status;

  /// The corners that triggered this state, if a document is present.
  final DocumentCorners? corners;

  /// How many consecutive qualifying frames have accumulated (0 when none).
  final int steadyFrames;

  /// Whether the caller should capture a still now.
  bool get shouldCapture => status == AutoCaptureStatus.ready;

  @override
  String toString() =>
      'AutoCaptureState($status, steady:$steadyFrames'
      '${corners == null ? '' : ', conf:${corners!.confidence?.toStringAsFixed(2)}'})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutoCaptureState &&
          other.status == status &&
          other.corners == corners &&
          other.steadyFrames == steadyFrames;

  @override
  int get hashCode => Object.hash(status, corners, steadyFrames);
}

/// Watches a stream of detected [DocumentCorners] and decides when a document
/// has been held **steady and confident** long enough to auto-capture.
///
/// This is a pure-Dart, camera-free analyzer — it owns no UI and no capture. It
/// turns the detector's `Stream<DocumentCorners?>` into a `Stream<AutoCapture
/// State>`; you wire the [AutoCaptureStatus.ready] signal to your own capture
/// (take a full-res still, then crop it). It is the composable counterpart to
/// the auto-capture that competitors bury inside a fixed camera UI.
///
/// A frame **qualifies** when a document is present, convex, large enough
/// ([minArea]), and above [minConfidence]. The analyzer fires `ready` once the
/// document has both qualified and stayed **still** (corner movement under
/// [maxJitter]) for [requiredSteadyFrames] consecutive frames. After firing it
/// latches until the document leaves or moves significantly, so a single hold
/// produces a single capture — not a burst.
class AutoCaptureAnalyzer {
  /// Creates an analyzer with the gating thresholds. The defaults are tuned for
  /// a live hand-held camera; tighten [minConfidence]/[minArea] or lower
  /// [maxJitter] to require a steadier, closer document, or raise
  /// [requiredSteadyFrames] to demand a longer hold before firing.
  AutoCaptureAnalyzer({
    this.requiredSteadyFrames = 2,
    this.minConfidence = 0,
    this.minArea = 0.10,
    this.maxJitter = 0.08,
  })  : assert(requiredSteadyFrames > 0),
        assert(minConfidence >= 0 && minConfidence <= 1),
        assert(minArea >= 0 && minArea <= 1),
        assert(maxJitter >= 0);

  /// Consecutive qualifying+steady frames required before firing `ready`.
  final int requiredSteadyFrames;

  /// Minimum [DocumentCorners.confidence] for a frame to qualify.
  final double minConfidence;

  /// Minimum normalized quad [DocumentCorners.area] for a frame to qualify —
  /// rejects a document too small/far to scan well.
  final double minArea;

  /// Maximum average corner movement (normalized) between two frames for them to
  /// count as "still". Above this the steady counter resets.
  final double maxJitter;

  int _steady = 0;
  DocumentCorners? _last;
  bool _latched = false;

  /// Feeds one detection result and returns the resulting state. Call this for
  /// every frame (pass `null` when nothing was detected).
  AutoCaptureState add(DocumentCorners? corners) {
    if (corners == null || !_qualifies(corners)) {
      _steady = 0;
      _last = null;
      _latched = false;
      return AutoCaptureState(
        status: corners == null
            ? AutoCaptureStatus.searching
            : AutoCaptureStatus.detecting,
        corners: corners,
      );
    }

    // Qualifying document: is it steady vs the previous qualifying frame?
    final steadyEnough = _last == null || _jitter(_last!, corners) <= maxJitter;
    if (steadyEnough) {
      _steady++;
    } else {
      _steady = 1; // moved — restart the steadiness count from this frame
      _latched = false;
    }
    _last = corners;

    if (_steady >= requiredSteadyFrames && !_latched) {
      _latched = true; // fire once per hold
      return AutoCaptureState(
        status: AutoCaptureStatus.ready,
        corners: corners,
        steadyFrames: _steady,
      );
    }

    // Qualifying and accumulating, but either not steady long enough yet or
    // already latched (we fired once and are waiting for the document to leave
    // or move before arming again).
    return AutoCaptureState(
      status: AutoCaptureStatus.detecting,
      corners: corners,
      steadyFrames: _steady,
    );
  }

  /// Convenience: transform a raw corner stream into a state stream. Pairs with
  /// [bindEvents] for a [DetectionEvent] stream.
  Stream<AutoCaptureState> bindCorners(Stream<DocumentCorners?> detections) {
    return detections.map(add);
  }

  /// Feeds a [DetectionEvent] (as produced by [DocumentDetector.detectStream])
  /// and returns the resulting capture state — so the detector's stream pipes
  /// straight into auto-capture without the caller flattening events to
  /// `DocumentCorners?` (which would erase the [FrameDropped] / [DetectionError]
  /// distinction the event type exists to preserve).
  ///
  /// - [DocumentDetected] advances the steadiness/qualification logic as usual.
  /// - [NoDocument] and [DetectionError] are treated as "no document this frame"
  ///   (the countdown resets), the same as feeding `null` to [add].
  /// - [FrameDropped] is a backpressure skip, not a detection result, so it
  ///   holds the current state unchanged rather than resetting the countdown.
  AutoCaptureState addEvent(DetectionEvent event) {
    return switch (event) {
      DocumentDetected(:final corners) => add(corners),
      NoDocument() || DetectionError() => add(null),
      // A dropped frame carries no information — keep the state we already have.
      FrameDropped() => AutoCaptureState(
          status: _latched
              ? AutoCaptureStatus.ready
              : (_steady > 0
                  ? AutoCaptureStatus.detecting
                  : AutoCaptureStatus.searching),
          corners: _last,
          steadyFrames: _steady,
        ),
    };
  }

  /// Convenience: pipe a [DocumentDetector.detectStream] output straight into a
  /// capture-state stream, preserving the event distinctions (see [addEvent]).
  Stream<AutoCaptureState> bindEvents(Stream<DetectionEvent> events) {
    return events.map(addEvent);
  }

  /// Clears accumulated steadiness (e.g. after you've captured and want the next
  /// hold to require a fresh countdown).
  void reset() {
    _steady = 0;
    _last = null;
    _latched = false;
  }

  bool _qualifies(DocumentCorners c) {
    if (!c.isConvex) return false;
    if (c.area < minArea) return false;
    final conf = c.confidence;
    if (conf != null && conf < minConfidence) return false;
    return true;
  }

  /// Mean per-corner movement between two quads, in normalized units.
  double _jitter(DocumentCorners a, DocumentCorners b) {
    final pa = a.toList();
    final pb = b.toList();
    var sum = 0.0;
    for (var i = 0; i < 4; i++) {
      final dx = pa[i].x - pb[i].x;
      final dy = pa[i].y - pb[i].y;
      sum += math.sqrt(dx * dx + dy * dy);
    }
    return sum / 4;
  }
}
