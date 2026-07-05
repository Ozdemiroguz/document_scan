/// A composable, native-light document scanner for Flutter.
///
/// Two independent pieces you can use together or apart:
///
/// * [DocumentDetector] — finds the four corners of a document in a still image
///   or a live camera frame. Backed by the platform's own vision engine
///   (Apple Vision on iOS, OpenCV on Android) — no heavy model to bundle, no
///   OCR, no camera ownership.
/// * [DocumentProcessor] — takes those corners and perspective-corrects, crops,
///   and filters the image. Pure Dart.
///
/// The package is widget-free: it returns data ([DocumentCorners],
/// [ScannedDocument]), and you build whatever UI you like on top.
library;

export 'src/detector/document_detector.dart';
export 'src/processor/document_processor.dart';
export 'src/types/document_corners.dart';
export 'src/types/scan_filter.dart';
export 'src/types/scan_input.dart';
export 'src/types/scanned_document.dart';
