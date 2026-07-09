import 'dart:async';

import 'package:document_scan/document_scan.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A fake native side: records the calls it received and replies with a
  // scripted result. Wired through the real MethodChannel binary messenger so we
  // exercise the actual codec + the detector's encode/decode, not a stub.
  late List<MethodCall> calls;
  late Object? Function(MethodCall call) responder;
  late DocumentDetector detector;

  const channel = MethodChannel('com.oguzhan.document_scan/detector');

  setUp(() {
    calls = [];
    responder = (_) => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return responder(call);
    });
    detector = DocumentDetector(channel: channel);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  // A well-formed native reply (unordered points — detector must order them).
  Map<String, dynamic> nativeCorners() => {
        'topLeftX': 0.1, 'topLeftY': 0.1,
        'topRightX': 0.9, 'topRightY': 0.1,
        'bottomRightX': 0.9, 'bottomRightY': 0.9,
        'bottomLeftX': 0.1, 'bottomLeftY': 0.9,
      };

  group('detect() method + argument encoding', () {
    test('file input calls detectFile with the path', () async {
      responder = (_) => nativeCorners();
      await detector.detect(ScanInput.file('/tmp/doc.jpg'));

      expect(calls, hasLength(1));
      expect(calls.single.method, 'detectFile');
      expect(calls.single.arguments['path'], '/tmp/doc.jpg');
    });

    test('sensitivity defaults to balanced on the wire', () async {
      responder = (_) => nativeCorners();
      await detector.detect(ScanInput.file('/x.jpg'));
      expect(calls.single.arguments['sensitivity'], 'balanced');
    });

    test('sensitivity is passed through to the native side', () async {
      responder = (_) => nativeCorners();
      await detector.detect(
        ScanInput.file('/x.jpg'),
        sensitivity: DetectionSensitivity.lenient,
      );
      expect(calls.single.arguments['sensitivity'], 'lenient');
    });

    test('bytes input calls detectFrame with bytes + dimensions', () async {
      responder = (_) => nativeCorners();
      await detector.detect(
        ScanInput.bytes(Uint8List.fromList([1, 2, 3]), width: 640, height: 480),
      );

      expect(calls.single.method, 'detectFrame');
      expect(calls.single.arguments['width'], 640);
      expect(calls.single.arguments['height'], 480);
      expect(calls.single.arguments['bytes'], isA<Uint8List>());
    });

    test('yuv420 camera frame encodes planes + strides + format', () async {
      responder = (_) => nativeCorners();
      await detector.detect(
        ScanInput.cameraFrame(
          width: 1920,
          height: 1080,
          format: ScanImageFormat.yuv420,
          rotation: 90,
          yBytes: Uint8List.fromList([1]),
          uBytes: Uint8List.fromList([2]),
          vBytes: Uint8List.fromList([3]),
          yRowStride: 1920,
          uvRowStride: 960,
          uvPixelStride: 2,
        ),
      );

      final args = calls.single.arguments as Map;
      expect(calls.single.method, 'detectFrame');
      expect(args['format'], 'yuv420');
      expect(args['rotation'], 90);
      expect(args['yBytes'], isA<Uint8List>());
      expect(args['uBytes'], isA<Uint8List>());
      expect(args['vBytes'], isA<Uint8List>());
      expect(args['yRowStride'], 1920);
      expect(args['uvPixelStride'], 2);
    });

    test('bgra camera frame encodes format bgra', () async {
      responder = (_) => nativeCorners();
      await detector.detect(
        ScanInput.cameraFrame(
          width: 1280,
          height: 720,
          format: ScanImageFormat.bgra8888,
          bytes: Uint8List.fromList([9]),
          bytesPerRow: 5120,
        ),
      );

      final args = calls.single.arguments as Map;
      expect(args['format'], 'bgra');
      expect(args['bytesPerRow'], 5120);
    });
  });

  group('detect() result decoding', () {
    test('orders the native reply into TL/TR/BR/BL', () async {
      // Reply with points in a scrambled order; the detector must normalize.
      responder = (_) => {
            'topLeftX': 0.9, 'topLeftY': 0.9, // actually BR
            'topRightX': 0.1, 'topRightY': 0.1, // actually TL
            'bottomRightX': 0.1, 'bottomRightY': 0.9, // actually BL
            'bottomLeftX': 0.9, 'bottomLeftY': 0.1, // actually TR
          };
      final c = await detector.detect(ScanInput.file('/x.jpg'));

      expect(c, isNotNull);
      expect(c!.topLeft, (x: 0.1, y: 0.1));
      expect(c.bottomRight, (x: 0.9, y: 0.9));
    });

    test('returns null when native reports no document', () async {
      responder = (_) => null;
      final c = await detector.detect(ScanInput.file('/x.jpg'));
      expect(c, isNull);
    });

    test('returns null (not a crash) on a malformed reply', () async {
      // A reply missing a coordinate key must degrade to "no detection", not
      // throw a cast error out of detect().
      responder = (_) => {
            'topLeftX': 0.1, 'topLeftY': 0.1,
            'topRightX': 0.9, // topRightY missing
            'bottomRightX': 0.9, 'bottomRightY': 0.9,
            'bottomLeftX': 0.1, 'bottomLeftY': 0.9,
          };
      final c = await detector.detect(ScanInput.file('/x.jpg'));
      expect(c, isNull);
    });

    test('returns null when a coordinate is a non-number', () async {
      responder = (_) => {
            ...nativeCorners(),
            'topLeftX': 'oops', // wrong type
          };
      final c = await detector.detect(ScanInput.file('/x.jpg'));
      expect(c, isNull);
    });

    test('prefers the native confidence when the platform supplies one', () async {
      responder = (_) => {...nativeCorners(), 'confidence': 0.42};
      final c = await detector.detect(ScanInput.file('/x.jpg'));
      expect(c!.confidence, closeTo(0.42, 1e-9));
    });

    test('derives a geometric confidence when native omits it', () async {
      // No 'confidence' key (Android/OpenCV) → detector fills it in from geometry.
      responder = (_) => nativeCorners();
      final c = await detector.detect(ScanInput.file('/x.jpg'));
      expect(c!.confidence, isNotNull);
      expect(c.confidence, inInclusiveRange(0.0, 1.0));
    });

    test('propagates a PlatformException from the native side', () async {
      responder = (_) => throw PlatformException(code: 'BOOM');
      expect(
        () => detector.detect(ScanInput.file('/x.jpg')),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('detectStream() backpressure', () {
    test('drops frames that arrive while one is still processing', () async {
      // Make the native call hang until we release it, so a second frame
      // arriving mid-flight is dropped rather than queued.
      final gate = Completer<void>();
      var nativeCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        nativeCalls++;
        await gate.future; // hold the first call open
        return nativeCorners();
      });

      final frames = StreamController<ScanInput>();
      final events = <DetectionEvent>[];
      final sub = detector.detectStream(frames.stream).listen(events.add);

      // Fire two frames back-to-back while the first is still in flight.
      frames.add(ScanInput.file('/1.jpg'));
      await Future<void>.delayed(Duration.zero);
      frames.add(ScanInput.file('/2.jpg')); // should be dropped (busy)
      await Future<void>.delayed(Duration.zero);

      gate.complete(); // release the first call
      await Future<void>.delayed(Duration.zero);

      // Only the first frame reached native; the second was dropped by the
      // busy guard and surfaced as a distinct DetectionSkipped event (not silence).
      expect(nativeCalls, 1);
      expect(events.whereType<DetectionSkipped>(), hasLength(1));
      expect(events.whereType<DetectionSuccess>(), hasLength(1));

      await sub.cancel();
      await frames.close();
    });

    test('emits DetectionError (not a raw throw) when a frame throws, and the '
        'stream stays alive', () async {
      responder = (_) => throw PlatformException(code: 'BAD_FRAME');
      final frames = StreamController<ScanInput>();
      final events = <DetectionEvent>[];
      final errors = <Object>[];
      final sub = detector.detectStream(frames.stream).listen(
            events.add,
            onError: errors.add,
          );

      frames.add(ScanInput.file('/1.jpg'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // The throw is delivered as a DetectionError event, not an onError, so the
      // stream is not torn down.
      expect(errors, isEmpty);
      expect(events, hasLength(1));
      final event = events.single;
      expect(event, isA<DetectionError>());
      expect((event as DetectionError).error, isA<PlatformException>());

      await sub.cancel();
      await frames.close();
    });

    test('emits DetectionEmpty when a frame holds no rectangle', () async {
      responder = (_) => null; // native found nothing
      final frames = StreamController<ScanInput>();
      final events = <DetectionEvent>[];
      final sub = detector.detectStream(frames.stream).listen(events.add);

      frames.add(ScanInput.file('/1.jpg'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(events, hasLength(1));
      expect(events.single, isA<DetectionEmpty>());

      await sub.cancel();
      await frames.close();
    });

    test('minInterval drops frames that arrive too soon, runs ones that dont',
        () async {
      // Drive time by hand so the throttle is deterministic (no sleeping).
      var now = DateTime(2026);
      final throttled = DocumentDetector(channel: channel, clock: () => now);
      responder = (_) => nativeCorners();

      final frames = StreamController<ScanInput>();
      final events = <DetectionEvent>[];
      final sub = throttled
          .detectStream(frames.stream,
              minInterval: const Duration(milliseconds: 100))
          .listen(events.add);

      // t=0: first frame runs (no previous timestamp to gate against).
      frames.add(ScanInput.file('/1.jpg'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // t=50ms: inside the 100ms window → dropped as DetectionSkipped.
      now = now.add(const Duration(milliseconds: 50));
      frames.add(ScanInput.file('/2.jpg'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // t=150ms: past the window → runs.
      now = now.add(const Duration(milliseconds: 100));
      frames.add(ScanInput.file('/3.jpg'));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(events.whereType<DetectionSuccess>(), hasLength(2),
          reason: 'frames 1 and 3 ran');
      expect(events.whereType<DetectionSkipped>(), hasLength(1),
          reason: 'frame 2 was rate-limited');

      await sub.cancel();
      await frames.close();
    });

    test('closes when the source stream is done', () async {
      responder = (_) => nativeCorners();
      final frames = StreamController<ScanInput>();
      var closed = false;
      final sub =
          detector.detectStream(frames.stream).listen((_) {}, onDone: () {
        closed = true;
      });

      await frames.close();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(closed, isTrue);

      await sub.cancel();
    });

    test('closing the source mid-detection does not throw (clean teardown)',
        () async {
      // Hold the native call open so the frame is still in flight when the
      // source stream completes — the realtime teardown case (stop scanning /
      // navigate away while a frame is being processed). The in-flight frame
      // must settle without adding to an already-closed controller.
      final gate = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        await gate.future;
        return nativeCorners();
      });

      final frames = StreamController<ScanInput>();
      final events = <DetectionEvent>[];
      final errors = <Object>[];
      Object? zoneError;

      await runZonedGuarded(() async {
        final sub = detector.detectStream(frames.stream).listen(
              events.add,
              onError: errors.add,
            );
        frames.add(ScanInput.file('/1.jpg'));
        await Future<void>.delayed(Duration.zero); // let detect() start
        await frames.close(); // onDone fires while the frame is in flight
        gate.complete(); // detect() resolves — must not add-after-close
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await sub.cancel();
      }, (e, _) => zoneError = e);

      expect(zoneError, isNull, reason: 'no add-after-close / unhandled error');
      expect(errors, isEmpty);
      // The in-flight frame still produced its event before the clean close.
      expect(events, hasLength(1));
      expect(events.single, isA<DetectionSuccess>());
    });
  });
}
