# document_scan

A composable, native-light document scanner for Flutter. Find a document's four
corners in a photo or a live camera frame, then perspective-correct and filter it
into a clean scan.

- **Composable, not a black box.** Two independent pieces — a `DocumentDetector`
  that finds corners and a `DocumentProcessor` that warps and filters. Use them
  together, or take just the part you need.
- **Widget-free.** The package returns *data* (corners, image bytes). You build
  the camera UI, the overlay, and the "capture" button exactly how you want.
- **Native-light.** Corner detection uses the platform's own vision engine —
  **Apple Vision on iOS (0 MB)** and **OpenCV on Android** — with no bundled ML
  model, no OCR, and no camera dependency.
- **Detects documents, not text.** A page is found by its rectangle, so blank
  pages, drawings, and forms work too.

## Install

```yaml
dependencies:
  document_scan: ^0.0.1
```

## Scan a still image

```dart
import 'package:document_scan/document_scan.dart';

final detector = DocumentDetector();
final processor = const DocumentProcessor();

final input = ScanInput.file('/path/to/photo.jpg');

// 1. Find the document's four corners (normalized 0..1, ordered TL/TR/BR/BL).
final corners = await detector.detect(input);

if (corners != null) {
  // 2. Perspective-correct + filter into an upright scan.
  final scan = await processor.crop(
    input,
    corners,
    filter: ScanFilter.blackWhite,
  );
  // scan!.bytes is a PNG — save it, show it with Image.memory, add it to a PDF…
}
```

## Scan from a live camera stream

The package never opens a camera. Feed it frames from your own capture (e.g. the
[`camera`](https://pub.dev/packages/camera) package) as `ScanInput`s:

```dart
final subscription = detector
    .detectStream(myCameraFrames) // Stream<ScanInput>
    .listen((corners) {
      // Draw `corners` in your overlay (a CustomPainter, etc.).
      setState(() => _corners = corners);
    });
```

Frames that arrive while a previous one is still being processed are dropped, so
the stream never backs up.

### Building a camera frame

```dart
final input = ScanInput.cameraFrame(
  width: image.width,
  height: image.height,
  format: ScanImageFormat.yuv420, // or .bgra8888 on iOS
  rotation: 90,
  // YUV420 (Android): pass the three planes + strides
  yBytes: image.planes[0].bytes,
  uBytes: image.planes[1].bytes,
  vBytes: image.planes[2].bytes,
  yRowStride: image.planes[0].bytesPerRow,
  uvRowStride: image.planes[1].bytesPerRow,
  uvPixelStride: image.planes[1].bytesPerPixel ?? 1,
);
```

## Filters

`DocumentProcessor` applies pure-Dart filters after cropping:

| `ScanFilter`   | Result                              |
| -------------- | ----------------------------------- |
| `none`         | The cropped color image, untouched. |
| `grayscale`    | Desaturated.                        |
| `blackWhite`   | High-contrast "scanned paper" look. |
| `sharpen`      | Crisper text edges.                 |

## What you get back

- `DocumentCorners` — four corners, always ordered top-left → top-right →
  bottom-right → bottom-left, normalized to 0..1. Ordering is derived
  geometrically, so it's consistent regardless of platform. Includes `area`,
  `isConvex`, `toPixels(w, h)` helpers.
- `ScannedDocument` — PNG bytes plus width/height.

## App size

Corner detection is native, but stays light:

| Platform | Engine        | Added size        |
| -------- | ------------- | ----------------- |
| iOS      | Apple Vision  | **0 MB** (OS)     |
| Android  | OpenCV        | native `.so`      |

On Android, ship only the ABIs your users need — a single-ABI (`arm64-v8a`)
release keeps OpenCV's footprint to roughly one architecture's worth instead of
all of them:

```gradle
// android/app/build.gradle
android {
  splits { abi { enable true; reset(); include 'arm64-v8a'; universalApk false } }
}
```

## Design

The package deliberately owns as little as possible: no camera, no OCR, no UI. It
gives you corners and pixels; everything above that is yours. If a native engine
is unavailable, detection returns `null` rather than throwing — your app keeps
running.

## License

MIT
