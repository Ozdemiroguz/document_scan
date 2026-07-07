import 'dart:async';

import 'package:flutter/services.dart';

import '../types/document_corners.dart';
import '../types/scan_input.dart';
import 'corner_stabilizer.dart';
import 'detection_event.dart';

/// Finds the four corners of a document in an image or camera frame.
///
/// Backed by the platform's native vision engine (Apple Vision on iOS, OpenCV
/// on Android) through a method channel. It detects a document as a
/// _rectangle_, not by its text — so blank pages, drawings and forms are found
/// too. It never opens a camera; you feed it images or frames.
///
/// Degrades gracefully: if the platform can't detect (or isn't implemented),
/// [detect] returns `null` and [detectStream] emits a [NoDocument] (or a
/// [DetectionError] carrying the failure) for that frame, rather than throwing.
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

  /// Runs detection over a stream of camera frames, emitting a [DetectionEvent]
  /// per handled frame so the consumer can tell *why* a frame produced no
  /// corners: [DocumentDetected], [NoDocument], [FrameDropped] (skipped under
  /// backpressure), or [DetectionError] (native threw — the stream stays alive).
  ///
  /// Frames that arrive while a previous one is still being processed are
  /// dropped (emitting [FrameDropped]) so the stream never backs up.
  ///
  /// Pass a [stabilize] filter to smooth jittery corners for an overlay — each
  /// [DocumentDetected] then carries the EMA-smoothed corners. Omit it for the
  /// raw per-frame corners.
  ///
  /// The package does not own the camera — pass frames from your own capture
  /// (e.g. the `camera` package's image stream) as [CameraFrameScanInput]s.
  Stream<DetectionEvent> detectStream(
    Stream<ScanInput> frames, {
    CornerStabilizer? stabilize,
  }) {
    late final StreamController<DetectionEvent> controller;
    var busy = false;
    var sourceDone = false;
    StreamSubscription<ScanInput>? sub;

    // Emit only while the controller is open. The source stream can complete
    // (onDone) while a frame's detect() is still awaiting — closing the
    // controller then would make the in-flight add() throw "add after close".
    void emit(DetectionEvent event) {
      if (!controller.isClosed) controller.add(event);
    }

    // Close only when the source is done AND no frame is in flight, so a
    // mid-flight frame settles into an event instead of adding to a closed sink.
    void closeIfIdle() {
      if (sourceDone && !busy && !controller.isClosed) controller.close();
    }

    controller = StreamController<DetectionEvent>(
      onListen: () {
        sub = frames.listen(
          (frame) async {
            if (busy) {
              emit(const FrameDropped());
              return; // drop frame — keep the pipeline responsive
            }
            busy = true;
            try {
              final corners = await detect(frame);
              final smoothed = stabilize == null
                  ? corners
                  : stabilize.add(corners);
              emit(
                smoothed == null
                    ? const NoDocument()
                    : DocumentDetected(smoothed),
              );
            } catch (e, st) {
              // Reset the smoother so a post-error document doesn't slide in
              // from a stale position.
              stabilize?.reset();
              emit(DetectionError(e, st));
            } finally {
              busy = false;
              closeIfIdle(); // the source may have completed mid-flight
            }
          },
          onError: (Object e, StackTrace st) {
            if (!controller.isClosed) controller.addError(e, st);
          },
          onDone: () {
            sourceDone = true;
            closeIfIdle();
          },
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
    // A malformed reply (a missing or non-numeric coordinate key) means "no
    // usable detection", not a crash — treat it as null rather than letting a
    // cast error escape `detect`.
    num? n(String k) => r[k] is num ? r[k] as num : null;
    final tlx = n('topLeftX'), tly = n('topLeftY');
    final trx = n('topRightX'), tryy = n('topRightY');
    final brx = n('bottomRightX'), bry = n('bottomRightY');
    final blx = n('bottomLeftX'), bly = n('bottomLeftY');
    if (tlx == null ||
        tly == null ||
        trx == null ||
        tryy == null ||
        brx == null ||
        bry == null ||
        blx == null ||
        bly == null) {
      return null;
    }
    // The native side returns four points; order them here so the engine's
    // vertex order is irrelevant.
    final corners = DocumentCorners.fromUnordered([
      (x: tlx.toDouble(), y: tly.toDouble()),
      (x: trx.toDouble(), y: tryy.toDouble()),
      (x: brx.toDouble(), y: bry.toDouble()),
      (x: blx.toDouble(), y: bly.toDouble()),
    ]);

    // Confidence: prefer the engine's own value when the platform supplies one
    // (iOS/Vision), otherwise derive a geometric heuristic (Android/OpenCV has
    // no probability). See DocumentCorners.confidence for the asymmetry.
    final native = r['confidence'];
    final confidence = native is num
        ? native.toDouble().clamp(0.0, 1.0)
        : corners.geometricConfidence();
    return corners.copyWith(confidence: confidence);
  }
}
