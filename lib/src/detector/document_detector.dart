import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../types/detection_sensitivity.dart';
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
/// [detect] returns `null` and [detectStream] emits a [DetectionEmpty] (or a
/// [DetectionError] carrying the failure) for that frame, rather than throwing.
class DocumentDetector {
  /// Creates a detector. [channel] is injectable for tests.
  DocumentDetector({
    MethodChannel? channel,
    @visibleForTesting DateTime Function()? clock,
  }) : _channel = channel ?? const MethodChannel(_channelName),
       _now = clock ?? DateTime.now;

  static const _channelName = 'com.oguzhan.document_scan/detector';

  final MethodChannel _channel;

  /// Wall-clock source for [detectStream]'s [minInterval] throttle. Injectable
  /// so a test can advance time deterministically instead of sleeping.
  final DateTime Function() _now;

  /// The aspect gate iOS applies when [detect]'s `minimumAspectRatio` is left
  /// `null`: a rectangle's short side must be at least 0.3 of its long side.
  static const double defaultMinimumAspectRatio = 0.3;

  /// Detects the document corners in a single [input].
  ///
  /// [sensitivity] tunes how eagerly a rectangle counts as a document (see
  /// [DetectionSensitivity]). For a one-shot scan of a file the user chose,
  /// [DetectionSensitivity.lenient] finds more; the default is
  /// [DetectionSensitivity.balanced].
  ///
  /// [minimumAspectRatio] lowers (or raises) the narrowest shape that still
  /// counts as a document, as the short side divided by the long side, in
  /// 0..1. **iOS only**: it maps to Vision's
  /// `VNDetectRectanglesRequest.minimumAspectRatio`, which otherwise stays at
  /// [defaultMinimumAspectRatio] (0.3, about 3.3:1) to reject slivers such as
  /// a table edge. A long receipt is narrower than that — 58 mm × 240 mm is
  /// about 0.24 — so pass something like `0.1` to find one. Leave it `null` to
  /// keep the default. Android ignores it: its OpenCV pipeline has no aspect
  /// gate at detection time.
  ///
  /// Returns ordered [DocumentCorners] (normalized 0..1), or `null` when no
  /// document-like rectangle is found. Throws only on an unexpected channel
  /// error you'd want to surface.
  ///
  /// ```dart
  /// final corners = await detector.detect(ScanInput.file('/path/to/photo.jpg'));
  /// if (corners != null) {
  ///   // corners.topLeft / topRight / bottomRight / bottomLeft are (x, y) in 0..1
  ///   // — draw them, let the user confirm, or feed them to DocumentProcessor.
  /// }
  /// ```
  Future<DocumentCorners?> detect(
    ScanInput input, {
    DetectionSensitivity sensitivity = DetectionSensitivity.balanced,
    double? minimumAspectRatio,
  }) async {
    _checkMinimumAspectRatio(minimumAspectRatio);
    final args = {
      ..._encode(input, sensitivity),
      'minimumAspectRatio': ?minimumAspectRatio,
    };
    final method = input is FileScanInput ? 'detectFile' : 'detectFrame';
    final result = await _channel.invokeMapMethod<String, dynamic>(
      method,
      args,
    );
    return _decode(result);
  }

  /// Runs detection over a stream of camera frames, emitting a [DetectionEvent]
  /// per handled frame so the consumer can tell *why* a frame produced no
  /// corners: [DetectionSuccess], [DetectionEmpty], [DetectionSkipped] (skipped under
  /// backpressure), or [DetectionError] (native threw — the stream stays alive).
  ///
  /// Frames that arrive while a previous one is still being processed are
  /// dropped (emitting [DetectionSkipped]) so the stream never backs up.
  ///
  /// Pass [minInterval] to cap the detection rate: a frame that arrives sooner
  /// than [minInterval] after the previous *processed* one is dropped (as a
  /// [DetectionSkipped]) before it reaches the native engine. A camera can push
  /// 30–60 frames a second; running native detection on every one wastes CPU/GPU
  /// and heats the device without making the overlay look any smoother. A value
  /// around `Duration(milliseconds: 100)` (~10 detections/second) keeps the
  /// overlay live while cutting the work several-fold. Omit it (the default) to
  /// detect as fast as the engine can, bounded only by the busy guard below.
  ///
  /// Pass a [stabilize] filter to smooth jittery corners for an overlay — each
  /// [DetectionSuccess] then carries the EMA-smoothed corners. Omit it for the
  /// raw per-frame corners.
  ///
  /// [minimumAspectRatio] is applied to every frame; see [detect]. It is
  /// iOS-only and ignored on Android.
  ///
  /// The package does not own the camera — pass frames from your own capture
  /// (e.g. the `camera` package's image stream) as [CameraFrameScanInput]s.
  ///
  /// ```dart
  /// final sub = detector
  ///     .detectStream(
  ///       myCameraFrames, // Stream<ScanInput>
  ///       stabilize: CornerStabilizer(), // smooth the overlay
  ///       minInterval: const Duration(milliseconds: 100), // ~10 fps
  ///     )
  ///     .listen((event) {
  ///       switch (event) {
  ///         case DetectionSuccess(:final corners):
  ///           setState(() => _corners = corners); // draw in your overlay
  ///         case DetectionEmpty():
  ///           setState(() => _corners = null); // "point at a document"
  ///         case DetectionSkipped():
  ///           break; // dropped under load — normal, ignore
  ///         case DetectionError(:final error):
  ///           debugPrint('detect failed: $error'); // stream stays alive
  ///       }
  ///     });
  /// ```
  Stream<DetectionEvent> detectStream(
    Stream<ScanInput> frames, {
    CornerStabilizer? stabilize,
    DetectionSensitivity sensitivity = DetectionSensitivity.strict,
    Duration? minInterval,
    double? minimumAspectRatio,
  }) {
    _checkMinimumAspectRatio(minimumAspectRatio);
    late final StreamController<DetectionEvent> controller;
    var busy = false;
    var sourceDone = false;
    DateTime? lastStarted;
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
              emit(const DetectionSkipped());
              return; // drop frame — keep the pipeline responsive
            }
            // Rate cap: skip a frame that arrives sooner than minInterval after
            // the previous processed one. Measured from the last frame we *ran*
            // (not the last arrival), so dropped frames don't reset the clock.
            if (minInterval != null && lastStarted != null) {
              if (_now().difference(lastStarted!) < minInterval) {
                emit(const DetectionSkipped());
                return;
              }
            }
            busy = true;
            lastStarted = _now();
            try {
              final corners = await detect(
                frame,
                sensitivity: sensitivity,
                minimumAspectRatio: minimumAspectRatio,
              );
              final smoothed = stabilize == null
                  ? corners
                  : stabilize.add(corners);
              emit(
                smoothed == null
                    ? const DetectionEmpty()
                    : DetectionSuccess(smoothed),
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

  // Same contract as Vision's own property: a ratio of short to long side.
  static void _checkMinimumAspectRatio(double? value) {
    assert(
      value == null || (value >= 0 && value <= 1),
      'minimumAspectRatio is 0..1 (short side / long side)',
    );
  }

  // --- encode / decode ---

  Map<String, dynamic> _encode(
    ScanInput input,
    DetectionSensitivity sensitivity,
  ) {
    final s = sensitivity.wireName;
    switch (input) {
      case FileScanInput(:final path):
        return {'path': path, 'sensitivity': s};
      case BytesScanInput(:final bytes, :final width, :final height):
        return {
          'bytes': bytes,
          'width': width,
          'height': height,
          'sensitivity': s,
        };
      case CameraFrameScanInput():
        // The chroma planes are deliberately NOT put on the wire. Detection is
        // a grayscale pipeline on both platforms — Android works straight off
        // the Y plane, iOS only ever handled BGRA — so marshalling U and V
        // would copy roughly `width * height / 2` bytes across the platform
        // channel, for every frame, into something nothing reads. At 1080p and
        // 30 fps that is tens of MB a second of pure overhead. Callers still
        // pass the planes (see [ScanInput.yuvFrame]); they just stop here.
        return {
          'width': input.width,
          'height': input.height,
          'rotation': input.rotation,
          'format': input.format == ScanImageFormat.yuv420 ? 'yuv420' : 'bgra',
          'sensitivity': s,
          'bytes': ?input.bytes,
          if (input.bytesPerRow > 0) 'bytesPerRow': input.bytesPerRow,
          'yBytes': ?input.yBytes,
          if (input.yRowStride > 0) 'yRowStride': input.yRowStride,
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
