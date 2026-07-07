## 0.1.0

Initial release.

- `DocumentScanner` — one-call scanning: `scan(input)` detects and crops; pass
  `corners:` to skip detection and crop user-adjusted corners instead.
- `DocumentDetector` — document corner detection for still images (`detect`) and
  live camera frames (`detectStream`), backed by Apple Vision on iOS and OpenCV
  on Android, with per-frame downscaling for realtime performance. `detectStream`
  emits a sealed `DetectionEvent` (`DetectionSuccess` / `DetectionEmpty` /
  `DetectionSkipped` / `DetectionError`) so a consumer can tell an empty scene from a
  backpressure drop from a native error, rather than a blind `null`. Corners
  carry a `confidence` (engine value on iOS, geometric heuristic on Android).
- `CornerStabilizer` — optional EMA smoothing for the live corner stream, so an
  overlay drawn from `detectStream(stabilize: ...)` stays steady instead of
  jittering; snaps rather than slides when the document jumps.
- `DocumentProcessor` — pure-Dart perspective correction (`crop`) with
  `grayscale`, `enhance`, `blackWhite`, `sharpen`, and adaptive `magicColor`
  filters. Output as PNG, JPEG (quality-tunable), or a single-page PDF via
  `ScanOutputFormat`. Undecodable input returns `null` rather than throwing.
- `AutoCaptureAnalyzer` — pure-Dart stream analyzer that signals when a document
  has been held steady and confident long enough to auto-capture.
- `ScanSession` — an immutable multi-page container (add / reorder / remove).
- Plugin-free value types: `ScanInput`, `DocumentCorners` (geometry-ordered
  corners + confidence), `ScannedDocument`, `ScanFilter`, `ScanOutputFormat`.
- Example app with four flows: gallery scan, realtime overlay (detectStream +
  CornerStabilizer + AutoCaptureAnalyzer over a live camera), manual corner
  edit (drag-adjust → crop with `corners:`), and reprocess (detect once, swap
  filters live). Plain `StatefulWidget`, no state-management dependency.
