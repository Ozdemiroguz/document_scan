/// Post-processing filters applied to a cropped document by
/// [DocumentProcessor]. Pure-Dart, so they add no native dependency.
enum ScanFilter {
  /// Leave the cropped color image untouched.
  none,

  /// Desaturate to grayscale — smaller, neutral scans.
  grayscale,

  /// High-contrast black & white — the classic "scanned paper" look.
  blackWhite,

  /// Sharpen edges to make text crisper.
  sharpen,
}
