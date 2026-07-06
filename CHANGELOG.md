## 0.1.0

Initial release.

- `DocumentScanner` — one-call scanning: `scan(input)` detects and crops; pass
  `corners:` to skip detection and crop user-adjusted corners instead.
- `DocumentDetector` — document corner detection for still images (`detect`) and
  live camera frames (`detectStream`), backed by Apple Vision on iOS and OpenCV
  on Android, with per-frame downscaling for realtime performance. Frames are
  dropped under backpressure so the pipeline never backs up. Corners carry a
  `confidence` (engine value on iOS, geometric heuristic on Android).
- `DocumentProcessor` — pure-Dart perspective correction (`crop`) with
  `grayscale`, `enhance`, `blackWhite`, `sharpen`, and adaptive `magicColor`
  filters. Output as PNG, JPEG (quality-tunable), or a single-page PDF via
  `ScanOutputFormat`. Undecodable input returns `null` rather than throwing.
- `AutoCaptureAnalyzer` — pure-Dart stream analyzer that signals when a document
  has been held steady and confident long enough to auto-capture.
- `ScanSession` — an immutable multi-page container (add / reorder / remove).
- Plugin-free value types: `ScanInput`, `DocumentCorners` (geometry-ordered
  corners + confidence), `ScannedDocument`, `ScanFilter`, `ScanOutputFormat`.
