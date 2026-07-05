## 0.1.0

Initial release.

- `DocumentDetector` — document corner detection for still images (`detect`) and
  live camera frames (`detectStream`), backed by Apple Vision on iOS and OpenCV
  on Android. Realtime frames are dropped under backpressure so the pipeline
  never backs up.
- `DocumentProcessor` — pure-Dart perspective correction (`crop`) with
  `grayscale`, `blackWhite`, and `sharpen` filters. Undecodable input returns
  `null` rather than throwing.
- Plugin-free value types: `ScanInput`, `DocumentCorners` (geometry-ordered
  corners), `ScannedDocument`, `ScanFilter`.
