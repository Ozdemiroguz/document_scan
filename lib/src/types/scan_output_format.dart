/// The encoded format a [ScannedDocument] is returned in.
enum ScanImageCodec {
  /// Lossless PNG — larger files, exact pixels. The default.
  png,

  /// Lossy JPEG — much smaller files, tunable via quality. Ideal for
  /// photo-like document scans destined for upload.
  jpeg,

  /// A single-page PDF wrapping the scan — the common "save my scan as a PDF"
  /// output (email, sign, archive). The page is A4 with the scan fit inside;
  /// for finer PDF control, take the image bytes and use a PDF library yourself.
  pdf,
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

  /// Single-page PDF output (the scan on an A4 page).
  static const pdf = ScanOutputFormat(codec: ScanImageCodec.pdf);

  /// The codec to encode with.
  final ScanImageCodec codec;

  /// JPEG quality (1..100). Ignored for PNG and PDF.
  final int quality;
}
