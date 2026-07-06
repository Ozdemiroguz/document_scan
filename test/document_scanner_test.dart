import 'package:document_scan/document_scan.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// A small solid PNG to scan.
Uint8List _png(int w, int h) {
  final image = img.Image(width: w, height: h, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(200, 200, 200));
  return Uint8List.fromList(img.encodePng(image));
}

/// Full-frame corners (the whole image is the document).
final _fullFrame = DocumentCorners.fromUnordered([
  (x: 0.0, y: 0.0),
  (x: 1.0, y: 0.0),
  (x: 1.0, y: 1.0),
  (x: 0.0, y: 1.0),
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.oguzhan.document_scan/detector');
  late int detectCalls;
  late Object? detectReply;

  setUp(() {
    detectCalls = 0;
    detectReply = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      detectCalls++;
      return detectReply;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  DocumentScanner scanner() =>
      DocumentScanner(detector: DocumentDetector(channel: channel));

  Map<String, dynamic> nativeCorners() => {
        'topLeftX': 0.0, 'topLeftY': 0.0,
        'topRightX': 1.0, 'topRightY': 0.0,
        'bottomRightX': 1.0, 'bottomRightY': 1.0,
        'bottomLeftX': 0.0, 'bottomLeftY': 1.0,
      };

  group('automatic mode (no corners given)', () {
    test('detects then crops, returning a document', () async {
      detectReply = nativeCorners();
      final out = await scanner().scan(
        ScanInput.bytes(_png(120, 160), width: 120, height: 160),
      );
      expect(detectCalls, 1); // detection ran
      expect(out, isNotNull);
      expect(out!.bytes, isNotEmpty);
    });

    test('returns null when no document is detected', () async {
      detectReply = null; // native: no rectangle
      final out = await scanner().scan(
        ScanInput.bytes(_png(120, 160), width: 120, height: 160),
      );
      expect(detectCalls, 1);
      expect(out, isNull);
    });
  });

  group('user-corrected mode (corners given)', () {
    test('skips detection and crops with the provided corners', () async {
      // If detection were called it would throw (no reply scripted for a real
      // crop), but it must NOT be called.
      final out = await scanner().scan(
        ScanInput.bytes(_png(120, 160), width: 120, height: 160),
        corners: _fullFrame,
      );
      expect(detectCalls, 0); // detection skipped entirely
      expect(out, isNotNull);
      expect(out!.width, closeTo(120, 2));
      expect(out.height, closeTo(160, 2));
    });
  });

  group('detectCorners()', () {
    test('exposes detection alone for a confirm/adjust UI', () async {
      detectReply = nativeCorners();
      final corners = await scanner().detectCorners(
        ScanInput.bytes(_png(100, 100), width: 100, height: 100),
      );
      expect(detectCalls, 1);
      expect(corners, isNotNull);
    });
  });

  test('honors the output format', () async {
    final out = await scanner().scan(
      ScanInput.bytes(_png(80, 80), width: 80, height: 80),
      corners: _fullFrame,
      output: const ScanOutputFormat.jpeg(quality: 80),
    );
    // JPEG magic bytes.
    expect(out!.bytes.sublist(0, 2), [0xFF, 0xD8]);
  });
}
