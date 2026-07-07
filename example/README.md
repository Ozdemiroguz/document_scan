# document_scan example

A four-screen tour of the [`document_scan`](https://pub.dev/packages/document_scan)
package. Each screen is a self-contained `StatefulWidget` (no state-management
library) so the package usage stays front and centre.

## Screens

| Screen | Demonstrates | Key API |
| --- | --- | --- |
| **Gallery scan** | The one-call façade: pick a photo → clean scan. | `DocumentScanner.scan(input, filter:)` |
| **Realtime overlay** | Live camera detection + smoothing + auto-capture, drawn as a quad overlay. | `DocumentDetector.detectStream(stabilize:)`, `CornerStabilizer`, `AutoCaptureAnalyzer` |
| **Manual corner edit** | Detect, drag the corners to correct, then crop with the user's quad. | `DocumentDetector.detect`, `DocumentScanner.scan(corners:)` |
| **Reprocess with filter** | Detect once, then re-crop with each filter (no re-detection). | `DocumentProcessor.crop(background: true)` |

## Notes

- **Off the UI thread.** The heavy warp is pure-Dart CPU work. The façade
  (`scan`) offloads it to a background isolate by default; the primitive
  (`crop`) does so when you pass `background: true`. No `Isolate.run` in this
  app — the package handles it.
- **Realtime overlay alignment is simplified.** Mapping detection corners onto
  the live preview pixel-perfectly needs the device's current rotation folded
  into both the frame rotation and a preview transform — camera plumbing, not
  package logic. The overlay may sit rotated on some devices; detection,
  smoothing, events and auto-capture are all real. See the screen's banner and
  doc comment.
- **Camera permission** is declared for the realtime screen
  (`NSCameraUsageDescription` on iOS, `CAMERA` on Android).

## Run

```sh
cd example
flutter run
```
