import 'dart:typed_data';

/// The pixel layout of a raw camera frame.
enum ScanImageFormat {
  /// Single interleaved BGRA plane (iOS camera default).
  bgra8888,

  /// Three-plane YUV 4:2:0 (Android camera default).
  yuv420,
}

/// An image to scan — a file, in-memory bytes, or a raw camera frame.
///
/// This is the single input type for both [DocumentDetector] and
/// [DocumentProcessor], so callers never have to juggle multiple overloads. It
/// is a sealed class: pattern-match on the variant when you need the specifics.
sealed class ScanInput {
  const ScanInput();

  /// A decodable image file on disk (JPEG/PNG/…).
  factory ScanInput.file(String path) = FileScanInput;

  /// Already-decoded image bytes plus their dimensions.
  factory ScanInput.bytes(Uint8List bytes, {required int width, required int height}) =
      BytesScanInput;

  /// A raw BGRA camera frame (the iOS camera default). [bytes] is the single
  /// interleaved BGRA plane; [bytesPerRow] is its row stride (0 assumes
  /// `width * 4`). [rotation] is the clockwise degrees (0/90/180/270) to bring
  /// the frame upright.
  ///
  /// Prefer this over [ScanInput.cameraFrame] for BGRA — it makes the required
  /// plane a required argument, so a wrong-format call can't compile.
  factory ScanInput.bgraFrame({
    required int width,
    required int height,
    required Uint8List bytes,
    int rotation,
    int bytesPerRow,
  }) = CameraFrameScanInput.bgra;

  /// A raw YUV 4:2:0 camera frame (the Android camera default). Pass the three
  /// planes ([yBytes]/[uBytes]/[vBytes]) and their strides. [rotation] is the
  /// clockwise degrees (0/90/180/270) to bring the frame upright.
  ///
  /// Prefer this over [ScanInput.cameraFrame] for YUV — it makes the three
  /// planes required, so a missing plane can't slip through.
  factory ScanInput.yuvFrame({
    required int width,
    required int height,
    required Uint8List yBytes,
    required Uint8List uBytes,
    required Uint8List vBytes,
    int rotation,
    int yRowStride,
    int uvRowStride,
    int uvPixelStride,
  }) = CameraFrameScanInput.yuv;

  /// A raw camera frame — the low-level, format-agnostic constructor. Most
  /// callers should use [ScanInput.bgraFrame] or [ScanInput.yuvFrame], which
  /// require exactly the planes their format needs. Here the plane/stride params
  /// are all optional and it's on you to pass the right set for [format]:
  /// [bytes] (+[bytesPerRow]) for [ScanImageFormat.bgra8888], or
  /// [yBytes]/[uBytes]/[vBytes] with strides for [ScanImageFormat.yuv420].
  factory ScanInput.cameraFrame({
    required int width,
    required int height,
    required ScanImageFormat format,
    int rotation,
    Uint8List? bytes,
    int bytesPerRow,
    Uint8List? yBytes,
    Uint8List? uBytes,
    Uint8List? vBytes,
    int yRowStride,
    int uvRowStride,
    int uvPixelStride,
  }) = CameraFrameScanInput;
}

/// A file path input.
final class FileScanInput extends ScanInput {
  const FileScanInput(this.path);
  final String path;
}

/// A decoded-bytes input.
final class BytesScanInput extends ScanInput {
  const BytesScanInput(this.bytes, {required this.width, required this.height});
  final Uint8List bytes;
  final int width;
  final int height;
}

/// A raw camera-frame input (realtime).
final class CameraFrameScanInput extends ScanInput {
  const CameraFrameScanInput({
    required this.width,
    required this.height,
    required this.format,
    this.rotation = 0,
    this.bytes,
    this.bytesPerRow = 0,
    this.yBytes,
    this.uBytes,
    this.vBytes,
    this.yRowStride = 0,
    this.uvRowStride = 0,
    this.uvPixelStride = 1,
  });

  /// A BGRA frame: the single interleaved plane is required.
  const CameraFrameScanInput.bgra({
    required this.width,
    required this.height,
    required Uint8List this.bytes,
    this.rotation = 0,
    this.bytesPerRow = 0,
  })  : format = ScanImageFormat.bgra8888,
        yBytes = null,
        uBytes = null,
        vBytes = null,
        yRowStride = 0,
        uvRowStride = 0,
        uvPixelStride = 1;

  /// A YUV 4:2:0 frame: the three planes are required.
  const CameraFrameScanInput.yuv({
    required this.width,
    required this.height,
    required Uint8List this.yBytes,
    required Uint8List this.uBytes,
    required Uint8List this.vBytes,
    this.rotation = 0,
    this.yRowStride = 0,
    this.uvRowStride = 0,
    this.uvPixelStride = 1,
  })  : format = ScanImageFormat.yuv420,
        bytes = null,
        bytesPerRow = 0;

  /// Frame width in pixels.
  final int width;

  /// Frame height in pixels.
  final int height;

  /// Pixel layout of the frame — [ScanImageFormat.bgra8888] or
  /// [ScanImageFormat.yuv420].
  final ScanImageFormat format;

  /// Clockwise degrees (0/90/180/270) needed to bring the frame upright.
  final int rotation;

  /// Interleaved BGRA pixel bytes (used for [ScanImageFormat.bgra8888]).
  final Uint8List? bytes;

  /// Row stride of [bytes] in bytes; 0 if unspecified (assumes `width * 4`).
  final int bytesPerRow;

  /// Y (luma) plane bytes (used for [ScanImageFormat.yuv420]).
  final Uint8List? yBytes;

  /// U (chroma) plane bytes (used for [ScanImageFormat.yuv420]).
  final Uint8List? uBytes;

  /// V (chroma) plane bytes (used for [ScanImageFormat.yuv420]).
  final Uint8List? vBytes;

  /// Row stride of the Y plane in bytes.
  final int yRowStride;

  /// Row stride of the U/V planes in bytes.
  final int uvRowStride;

  /// Pixel stride of the U/V planes (1 for planar, 2 for semi-planar/NV21).
  final int uvPixelStride;
}
