/// The encoded image format a [ScannedDocument] is returned in.
enum ScanImageCodec {
  /// Lossless PNG — larger files, exact pixels. The default.
  png,

  /// Lossy JPEG — much smaller files, tunable via quality. Ideal for
  /// photo-like document scans destined for upload or PDF.
  jpeg,
}

/// How to encode a processed scan: the [codec] and, for JPEG, the [quality].
class ScanOutputFormat {
  const ScanOutputFormat({
    this.codec = ScanImageCodec.png,
    this.quality = 90,
  }) : assert(quality >= 1 && quality <= 100, 'quality is 1..100');

  /// PNG output (lossless).
  static const png = ScanOutputFormat();

  /// JPEG output at the given [quality] (1..100).
  const ScanOutputFormat.jpeg({int quality = 90})
      : this(codec: ScanImageCodec.jpeg, quality: quality);

  /// The image codec to encode with.
  final ScanImageCodec codec;

  /// JPEG quality (1..100). Ignored for PNG.
  final int quality;
}
