import 'dart:async';

import 'package:flutter/services.dart';

import '../types/document_corners.dart';
import '../types/scan_input.dart';

/// Finds the four corners of a document in an image or camera frame.
///
/// Backed by the platform's native vision engine (Apple Vision on iOS, OpenCV
/// on Android) through a method channel. It detects a document as a
/// _rectangle_, not by its text — so blank pages, drawings and forms are found
/// too. It never opens a camera; you feed it images or frames.
///
/// Degrades gracefully: if the platform can't detect (or isn't implemented),
/// [detect] returns `null` and [detectStream] simply emits nothing for that
/// frame, rather than throwing.
class DocumentDetector {
  /// Creates a detector. [channel] is injectable for tests.
  DocumentDetector({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'com.oguzhan.document_scan/detector';

  final MethodChannel _channel;

  /// Detects the document corners in a single [input].
  ///
  /// Returns ordered [DocumentCorners] (normalized 0..1), or `null` when no
  /// document-like rectangle is found. Throws only on an unexpected channel
  /// error you'd want to surface.
  Future<DocumentCorners?> detect(ScanInput input) async {
    final args = _encode(input);
    final method = input is FileScanInput ? 'detectFile' : 'detectFrame';
    final result = await _channel.invokeMapMethod<String, dynamic>(method, args);
    return _decode(result);
  }

  /// Runs detection over a stream of camera frames, emitting the latest corners
  /// (or `null` when none are found). Frames that arrive while a previous one is
  /// still being processed are dropped, so the stream never backs up.
  ///
  /// The package does not own the camera — pass frames from your own capture
  /// (e.g. the `camera` package's image stream) as [CameraFrameScanInput]s.
  Stream<DocumentCorners?> detectStream(Stream<ScanInput> frames) {
    late final StreamController<DocumentCorners?> controller;
    var busy = false;
    StreamSubscription<ScanInput>? sub;

    controller = StreamController<DocumentCorners?>(
      onListen: () {
        sub = frames.listen(
          (frame) async {
            if (busy) return; // drop frame — keep the pipeline responsive
            busy = true;
            try {
              controller.add(await detect(frame));
            } catch (_) {
              controller.add(null);
            } finally {
              busy = false;
            }
          },
          onError: controller.addError,
          onDone: controller.close,
        );
      },
      onCancel: () async {
        await sub?.cancel();
      },
    );
    return controller.stream;
  }

  // --- encode / decode ---

  Map<String, dynamic> _encode(ScanInput input) {
    switch (input) {
      case FileScanInput(:final path):
        return {'path': path};
      case BytesScanInput(:final bytes, :final width, :final height):
        return {'bytes': bytes, 'width': width, 'height': height};
      case CameraFrameScanInput():
        return {
          'width': input.width,
          'height': input.height,
          'rotation': input.rotation,
          'format': input.format == ScanImageFormat.yuv420 ? 'yuv420' : 'bgra',
          'bytes': ?input.bytes,
          if (input.bytesPerRow > 0) 'bytesPerRow': input.bytesPerRow,
          'yBytes': ?input.yBytes,
          'uBytes': ?input.uBytes,
          'vBytes': ?input.vBytes,
          if (input.yRowStride > 0) 'yRowStride': input.yRowStride,
          if (input.uvRowStride > 0) 'uvRowStride': input.uvRowStride,
          'uvPixelStride': input.uvPixelStride,
        };
    }
  }

  DocumentCorners? _decode(Map<String, dynamic>? r) {
    if (r == null) return null;
    double v(String k) => (r[k] as num).toDouble();
    // The native side returns four points; order them here so the engine's
    // vertex order is irrelevant.
    return DocumentCorners.fromUnordered([
      (x: v('topLeftX'), y: v('topLeftY')),
      (x: v('topRightX'), y: v('topRightY')),
      (x: v('bottomRightX'), y: v('bottomRightY')),
      (x: v('bottomLeftX'), y: v('bottomLeftY')),
    ]);
  }
}
