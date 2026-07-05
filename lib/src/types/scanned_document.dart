import 'dart:typed_data';

/// The result of processing a document: a perspective-corrected, cropped, and
/// optionally filtered image, returned as encoded bytes plus its dimensions.
///
/// The bytes are a standard encoded image (PNG) so callers can save them, show
/// them with `Image.memory`, hand them to a PDF library, etc. — the package
/// makes no assumption about what you do next.
class ScannedDocument {
  const ScannedDocument({
    required this.bytes,
    required this.width,
    required this.height,
  });

  /// Encoded image bytes — PNG by default, or JPEG when the processor was given
  /// a JPEG [ScanOutputFormat]. Standard encoded bytes either way, so they save,
  /// display with `Image.memory`, or hand to a PDF library directly.
  final Uint8List bytes;

  /// Width of the processed image, in pixels.
  final int width;

  /// Height of the processed image, in pixels.
  final int height;

  @override
  String toString() => 'ScannedDocument(${width}x$height, ${bytes.length} B)';
}
