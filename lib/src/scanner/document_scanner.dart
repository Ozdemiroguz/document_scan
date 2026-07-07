import '../detector/document_detector.dart';
import '../processor/document_processor.dart';
import '../types/document_corners.dart';
import '../types/scan_filter.dart';
import '../types/scan_output_format.dart';
import '../types/scan_input.dart';
import '../types/scanned_document.dart';

/// One-call document scanning that ties [DocumentDetector] and
/// [DocumentProcessor] together — detect the document, then perspective-correct
/// and filter it — while leaving both pieces usable on their own.
///
/// It supports the two workflows a scanner needs, through a single method:
///
/// * **Fully automatic** — give it just an image; it finds the corners and
///   returns the cropped, filtered document. Call `scan(input)`.
/// * **User-corrected** — you already have corners (e.g. the user dragged them
///   to fix a mis-detection); it skips detection and crops with exactly those.
///   Call `scan(input, corners: edited)`.
///
/// Both return a [ScannedDocument] (encoded bytes + dimensions) — save it or
/// show it with `Image.memory`. Pass `output: ScanOutputFormat.pdf` to get the
/// scan back as a single-page PDF instead of an image. The detector and
/// processor are injectable for testing.
class DocumentScanner {
  /// Creates a scanner. Both collaborators are injectable: pass a
  /// [detector] to stub corner detection in tests, and/or a [processor] to
  /// reuse a shared (stateless) instance. Defaults construct a platform
  /// [DocumentDetector] and a `const DocumentProcessor`.
  DocumentScanner({
    DocumentDetector? detector,
    this.processor = const DocumentProcessor(),
  }) : _detector = detector ?? DocumentDetector();

  final DocumentDetector _detector;

  /// The processor used to crop/filter after detection. Exposed so callers can
  /// reuse the same instance (it's stateless, so a shared const is fine).
  final DocumentProcessor processor;

  /// Scans [input] into a clean, upright document.
  ///
  /// When [corners] is null the document's corners are detected first; if none
  /// are found (no document-like rectangle), this returns null. When [corners]
  /// is provided, detection is skipped and the image is cropped with exactly
  /// those — the path for a manual corner adjustment.
  ///
  /// [filter] post-processes the result (default [ScanFilter.enhance] for a
  /// clean scanned look); [output] picks the encoding (default PNG).
  /// [maxDimension] caps the output's long side (see [DocumentProcessor.crop]);
  /// pass `null` to warp at full resolution.
  ///
  /// [background] runs the CPU-heavy crop on a background isolate so the UI
  /// stays responsive — it defaults to `true` here because this façade is the
  /// simple, opinionated entry point and a full-frame crop otherwise janks the
  /// UI. (Detection stays on this isolate regardless: it's a native platform
  /// channel, already off the UI thread, and can't run inside an isolate.) Pass
  /// `false` if you're already calling this from your own background isolate, to
  /// avoid a redundant isolate hop.
  Future<ScannedDocument?> scan(
    ScanInput input, {
    DocumentCorners? corners,
    ScanFilter filter = ScanFilter.enhance,
    ScanOutputFormat output = ScanOutputFormat.png,
    int? maxDimension = DocumentProcessor.defaultMaxDimension,
    bool background = true,
  }) async {
    final quad = corners ?? await _detector.detect(input);
    if (quad == null) return null;
    return processor.crop(
      input,
      quad,
      filter: filter,
      output: output,
      maxDimension: maxDimension,
      background: background,
    );
  }

  /// Detects the document corners in [input] without cropping — useful when you
  /// want to show the detected quad for the user to confirm or adjust before
  /// calling [scan] with the (possibly edited) corners.
  Future<DocumentCorners?> detectCorners(ScanInput input) =>
      _detector.detect(input);
}
