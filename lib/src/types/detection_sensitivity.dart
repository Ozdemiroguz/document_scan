/// How eagerly the detector accepts a rectangle as a document.
///
/// The two native engines have completely different knobs — Apple Vision uses a
/// confidence + minimum-size gate, Android/OpenCV uses a contour-area threshold
/// and edge sensitivity — so a single raw number couldn't mean the same thing on
/// both. This enum is the portable control: the package maps each level to the
/// right per-platform thresholds so the *behaviour* is consistent even though the
/// underlying parameters aren't.
///
/// Pick by context, not platform:
/// - [strict] for a live camera stream, where you don't want the overlay
///   snapping onto tabletops, shadows, or half-framed guesses while the user is
///   still positioning the document.
/// - [lenient] for a one-shot scan of a file the user explicitly chose — they've
///   already said "this is a document", so failing to find it is the worse
///   outcome.
/// - [balanced] (the default) sits in between and suits most uses.
enum DetectionSensitivity {
  /// Only strong, well-framed, document-shaped rectangles. Fewer false
  /// positives, but a faint or partly-framed document may be missed. Best for
  /// realtime overlays.
  strict,

  /// A sensible middle ground — the default.
  balanced,

  /// Accept weaker / smaller / lower-contrast rectangles. Finds more, at the
  /// cost of the occasional false positive. Best for one-shot scans where the
  /// user already committed to a document.
  lenient;

  /// The wire value sent to the native side.
  String get wireName => name;
}
