import 'dart:math' as math;

import '../types/document_corners.dart';

/// Smooths jittery per-frame corners into a steady overlay quad.
///
/// Raw detection returns slightly different corners every frame even for a
/// perfectly still document — sub-pixel edge noise makes an overlay drawn
/// straight from them shimmer. This applies a per-corner exponential moving
/// average (EMA): each new frame nudges the displayed corner a fraction
/// [smoothing] of the way toward the raw corner, so small jitter averages out
/// while real movement still tracks.
///
/// It is deliberately tiny, pure, and optional — feed it corners yourself, or
/// pass it to `DocumentDetector.detectStream(stabilize: ...)`. It holds one
/// frame of state, so use one instance per detection session and [reset] it (or
/// let it auto-reset) when the document leaves.
///
/// ```dart
/// final stabilizer = CornerStabilizer();
/// // per frame:
/// final smooth = stabilizer.add(rawCorners); // null when no document
/// ```
class CornerStabilizer {
  /// [smoothing] in (0..1] is the weight given to each new frame: 1.0 disables
  /// smoothing (always the raw corner), lower is steadier but laggier. The
  /// default 0.5 halves jitter each frame while staying responsive.
  ///
  /// [resetDistance] (normalized 0..1) is a jump threshold: if any corner moves
  /// more than this between frames, the document is assumed to have changed
  /// (moved fast, swapped, or re-detected elsewhere) and the average snaps to
  /// the new position instead of sliding across the frame.
  CornerStabilizer({this.smoothing = 0.5, this.resetDistance = 0.2})
      : assert(smoothing > 0 && smoothing <= 1),
        assert(resetDistance > 0);

  final double smoothing;
  final double resetDistance;

  DocumentCorners? _last;

  /// Feeds the next frame's corners and returns the smoothed corners.
  ///
  /// Passing `null` (no document this frame) [reset]s the filter and returns
  /// `null`, so a document reappearing starts fresh rather than sliding in from
  /// its last position.
  DocumentCorners? add(DocumentCorners? raw) {
    if (raw == null) {
      _last = null;
      return null;
    }
    final prev = _last;
    if (prev == null || _maxCornerJump(prev, raw) > resetDistance) {
      // First frame, or a jump too large to be jitter — snap, don't slide.
      _last = raw;
      return raw;
    }

    ScanPoint lerp(ScanPoint a, ScanPoint b) => (
          x: a.x + (b.x - a.x) * smoothing,
          y: a.y + (b.y - a.y) * smoothing,
        );

    final smoothed = DocumentCorners(
      topLeft: lerp(prev.topLeft, raw.topLeft),
      topRight: lerp(prev.topRight, raw.topRight),
      bottomRight: lerp(prev.bottomRight, raw.bottomRight),
      bottomLeft: lerp(prev.bottomLeft, raw.bottomLeft),
      // Carry the newest confidence — it describes the raw detection, not the
      // smoothed geometry, and shouldn't be averaged.
      confidence: raw.confidence,
    );
    _last = smoothed;
    return smoothed;
  }

  /// Clears the filter state; the next [add] returns its input unchanged.
  void reset() => _last = null;

  static double _maxCornerJump(DocumentCorners a, DocumentCorners b) {
    final pa = a.toList();
    final pb = b.toList();
    var maxSq = 0.0;
    for (var i = 0; i < 4; i++) {
      final dx = pa[i].x - pb[i].x;
      final dy = pa[i].y - pb[i].y;
      final d = dx * dx + dy * dy; // squared distance
      if (d > maxSq) maxSq = d;
    }
    return math.sqrt(maxSq);
  }
}
