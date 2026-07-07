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
  document_scan: ^0.1.0
```

## Scan a still image

The one-call path — `DocumentScanner` detects the corners and returns a clean,
upright scan:

```dart
import 'package:document_scan/document_scan.dart';

final scanner = DocumentScanner();

final scan = await scanner.scan(ScanInput.file('/path/to/photo.jpg'));
// null when no document-like rectangle is found.
if (scan != null) {
  // scan.bytes is a PNG by default — show it with Image.memory, save it, …
  Image.memory(scan.bytes);
}
```

Pick a filter or a different output encoding:

```dart
final pdf = await scanner.scan(
  ScanInput.file(path),
  filter: ScanFilter.enhance,       // clean "scanned" look (the default)
  output: ScanOutputFormat.pdf,     // or .jpeg(quality: 92); default is PNG
);
// pdf!.bytes is now a single-page A4 PDF.
```

Already have user-corrected corners (e.g. from a drag-to-adjust overlay)?
Pass them and detection is skipped:

```dart
final scan = await scanner.scan(input, corners: editedCorners);
```

### …or compose the pieces yourself

`DocumentScanner` is a thin tie between two independent pieces you can use on
their own — a `DocumentDetector` (finds corners) and a `DocumentProcessor`
(warps + filters):

```dart
final detector = DocumentDetector();
final processor = const DocumentProcessor();

final input = ScanInput.file('/path/to/photo.jpg');

// 1. Find the document's four corners (normalized 0..1, ordered TL/TR/BR/BL).
final corners = await detector.detect(input);

if (corners != null) {
  // 2. Perspective-correct + filter into an upright scan.
  final scan = await processor.crop(input, corners, filter: ScanFilter.enhance);
  // scan!.bytes — save it, show it with Image.memory, …
}
```

## Scan from a live camera stream

The package never opens a camera. Feed it frames from your own capture (e.g. the
[`camera`](https://pub.dev/packages/camera) package) as `ScanInput`s. Each frame
yields a `DetectionEvent` so you can tell *why* a frame had no corners — no
document, a dropped frame under load, or a detection error — instead of a
blind `null`:

```dart
final subscription = detector
    .detectStream(myCameraFrames) // Stream<ScanInput>
    .listen((event) {
      switch (event) {
        case DocumentDetected(:final corners):
          setState(() => _corners = corners); // draw in your overlay
        case NoDocument():
          setState(() => _corners = null);    // hint: "point at a document"
        case FrameDropped():
          break; // normal backpressure under load — ignore
        case DetectionError(:final error):
          debugPrint('detect failed: $error'); // stream stays alive
      }
    });
```

### Steady overlay (corner stabilization)

Raw corners jitter a pixel or two every frame even for a still document. Pass a
`CornerStabilizer` to smooth them for the overlay — an exponential moving
average that damps jitter but still tracks real movement, and snaps (rather than
slides) when the document jumps:

```dart
detector.detectStream(myCameraFrames, stabilize: CornerStabilizer());
// DocumentDetected.corners are now smoothed. Tune CornerStabilizer(smoothing:,
// resetDistance:) for steadier-but-laggier vs snappier.
```

### Auto-capture

Wire `AutoCaptureAnalyzer` to fire once the document has been held steady and
confident long enough — you take the still and crop it:

```dart
final analyzer = AutoCaptureAnalyzer();

// Pipe the detector's event stream straight in — bindEvents keeps the
// FrameDropped / DetectionError distinction (a dropped frame holds the
// countdown; a lost document resets it):
analyzer.bindEvents(detector.detectStream(frames)).listen((state) {
  if (state.status == AutoCaptureStatus.ready) capture();
});

// Or, if you already have a plain corner stream, use bindCorners(cornerStream)
// — or call analyzer.add(corners) yourself per frame.
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

| `ScanFilter`   | Result                                       |
| -------------- | -------------------------------------------- |
| `none`         | The cropped color image, untouched.          |
| `grayscale`    | Desaturated.                                 |
| `enhance`      | Grayscale + contrast + normalize — the clean, readable "scanned" default. |
| `blackWhite`   | High-contrast "scanned paper" look.          |
| `sharpen`      | Crisper text edges.                          |
| `magicColor`   | Brightened, saturated color for photos/receipts. |

## Output formats

`output:` picks how the scan is encoded — the same cropped, filtered image, a
different container:

| `ScanOutputFormat`       | `bytes` are…                          |
| ------------------------ | ------------------------------------- |
| `ScanOutputFormat.png`   | PNG (the default).                    |
| `ScanOutputFormat.jpeg(quality: 92)` | JPEG at the given quality. |
| `ScanOutputFormat.pdf`   | A single-page A4 PDF of the scan.     |

## What you get back

- `DocumentCorners` — four corners, always ordered top-left → top-right →
  bottom-right → bottom-left, normalized to 0..1. Ordering is derived
  geometrically, so it's consistent regardless of platform. Carries a
  `confidence` (0..1 — the engine's own on iOS, a geometric heuristic on
  Android), plus `area`, `isConvex`, and `toPixels(w, h)` helpers.
- `ScannedDocument` — the encoded `bytes` (PNG / JPEG / PDF per `output`) plus
  the image `width`/`height`.

## Platform differences

Corner detection is native, and the two engines are not identical. None of this
leaks into the API — you always get normalized corners — but it affects *what*
gets detected, so it's documented honestly rather than hidden:

- **Detection engine.** iOS uses Apple Vision (`VNDetectRectanglesRequest`);
  Android uses an OpenCV contour pipeline. The same photo can be found on one
  platform and missed on the other, especially near the edges of detectability.
- **Aspect / size gating.** iOS applies Vision's own gates at detection
  (min aspect 0.1, max aspect 1.0, min size 5% of frame), so a very wide
  landscape document may be filtered out on iOS but not Android, which takes the
  largest convex quad and scores aspect only afterward.
- **`confidence` is not comparable across platforms.** On iOS it's Vision's own
  probability; on Android there is no native probability, so it's a geometric
  heuristic (convexity + area + aspect) with a ~0.4 floor. Don't reuse a single
  `minConfidence` / `AutoCaptureAnalyzer` threshold across platforms expecting
  identical behaviour — tune per platform if you gate on it.
- **Realtime frame format.** iOS streams accept **BGRA only**; Android accepts
  **YUV420 or BGRA**. Feed BGRA on iOS, YUV420 (or BGRA) on Android. `detectFile`
  (still images) has no such restriction.
- **Detection resolution.** Both platforms detect at a capped resolution for
  speed, and — importantly — the still-image and live-frame paths use the *same*
  cap so a document detects consistently whether it comes from the gallery or the
  camera. (Android caps both at 720px; iOS Vision's gates are resolution-relative,
  so its paths agree without an explicit cap.)

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
