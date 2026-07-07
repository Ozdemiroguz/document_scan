import '../types/document_corners.dart';

/// The outcome of a single frame in [DocumentDetector.detectStream].
///
/// A raw `Stream<DocumentCorners?>` cannot tell a developer *why* a frame
/// produced no corners — "no document in view" reads the same as "the frame was
/// dropped under load" or "native detection threw". This sealed type keeps those
/// cases distinct so you can react correctly: show a "hold steady" hint for
/// [DetectionEmpty], ignore [DetectionSkipped] as normal backpressure, and
/// log/report a [DetectionError] instead of silently treating a persistent
/// native failure as an empty scene.
///
/// The variant names share the `Detection` prefix so they read as a family and
/// don't collide with generic identifiers when the package is imported without
/// a prefix.
///
/// Pattern-match it:
/// ```dart
/// detector.detectStream(frames).listen((event) {
///   switch (event) {
///     case DetectionSuccess(:final corners): overlay.show(corners);
///     case DetectionEmpty():                 overlay.hint('Point at a document');
///     case DetectionSkipped():               /* normal under load — ignore */;
///     case DetectionError(:final error):     log.warn('detect failed', error);
///   }
/// });
/// ```
sealed class DetectionEvent {
  const DetectionEvent();
}

/// A document rectangle was found in the frame.
final class DetectionSuccess extends DetectionEvent {
  const DetectionSuccess(this.corners);

  /// The document's four corners (normalized 0..1). When corner stabilization
  /// is enabled these are the smoothed corners; otherwise the raw per-frame
  /// corners.
  final DocumentCorners corners;
}

/// The frame was processed but held no document-like rectangle. This is the
/// normal "nothing in view yet" signal — not an error.
final class DetectionEmpty extends DetectionEvent {
  const DetectionEmpty();
}

/// The frame was skipped because a previous frame was still being processed.
/// The stream drops frames under backpressure so it never backs up; this event
/// makes that visible rather than looking like an empty scene.
final class DetectionSkipped extends DetectionEvent {
  const DetectionSkipped();
}

/// Native detection threw for this frame. The stream stays alive (one bad frame
/// doesn't end the session); [error] is the thrown object for logging.
final class DetectionError extends DetectionEvent {
  const DetectionError(this.error, [this.stackTrace]);

  final Object error;
  final StackTrace? stackTrace;
}
