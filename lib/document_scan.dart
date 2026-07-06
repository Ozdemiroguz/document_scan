/// A composable, native-light document scanner for Flutter.
///
/// Use the one-call [DocumentScanner] for the common case, or compose the
/// independent pieces yourself:
///
/// * [DocumentScanner] — `scan(input)` detects and crops in one call; pass
///   `corners:` to skip detection and crop user-adjusted corners instead.
///
/// * [DocumentDetector] — finds the four corners of a document in a still image
///   or a live camera frame. Backed by the platform's own vision engine
///   (Apple Vision on iOS, OpenCV on Android) — no heavy model to bundle, no
///   OCR, no camera ownership.
/// * [DocumentProcessor] — takes those corners and perspective-corrects, crops,
///   and filters the image. Pure Dart.
/// * [AutoCaptureAnalyzer] — a pure-Dart, camera-free stream analyzer that
///   decides when a document has been held steady and confident long enough to
///   auto-capture. You wire its signal to your own capture.
///
/// The package is widget-free: it returns data ([DocumentCorners],
/// [ScannedDocument], [AutoCaptureState]), and you build whatever UI you like on
/// top.
library;

export 'src/detector/auto_capture_analyzer.dart';
export 'src/detector/document_detector.dart';
export 'src/processor/document_processor.dart';
export 'src/scanner/document_scanner.dart';
export 'src/session/scan_session.dart';
export 'src/types/document_corners.dart';
export 'src/types/scan_filter.dart';
export 'src/types/scan_input.dart';
export 'src/types/scan_output_format.dart';
export 'src/types/scanned_document.dart';
