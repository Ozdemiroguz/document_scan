import 'dart:typed_data';

import 'package:document_scan/document_scan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ScanInput.bgraFrame', () {
    test('sets format bgra8888 and the single plane; leaves YUV planes null', () {
      final input = ScanInput.bgraFrame(
        width: 640,
        height: 480,
        bytes: Uint8List.fromList([1, 2, 3, 4]),
        rotation: 90,
        bytesPerRow: 2560,
      ) as CameraFrameScanInput;

      expect(input.format, ScanImageFormat.bgra8888);
      expect(input.width, 640);
      expect(input.height, 480);
      expect(input.rotation, 90);
      expect(input.bytes, isNotNull);
      expect(input.bytesPerRow, 2560);
      // YUV planes must be absent so the native side reads the BGRA path.
      expect(input.yBytes, isNull);
      expect(input.uBytes, isNull);
      expect(input.vBytes, isNull);
    });
  });

  group('ScanInput.yuvFrame', () {
    test('sets format yuv420 and all three planes; leaves BGRA bytes null', () {
      final input = ScanInput.yuvFrame(
        width: 1920,
        height: 1080,
        yBytes: Uint8List.fromList([1]),
        uBytes: Uint8List.fromList([2]),
        vBytes: Uint8List.fromList([3]),
        rotation: 270,
        yRowStride: 1920,
        uvRowStride: 960,
        uvPixelStride: 2,
      ) as CameraFrameScanInput;

      expect(input.format, ScanImageFormat.yuv420);
      expect(input.rotation, 270);
      expect(input.yBytes, isNotNull);
      expect(input.uBytes, isNotNull);
      expect(input.vBytes, isNotNull);
      expect(input.yRowStride, 1920);
      expect(input.uvRowStride, 960);
      expect(input.uvPixelStride, 2);
      // The single-plane BGRA field must be absent.
      expect(input.bytes, isNull);
    });
  });
}
