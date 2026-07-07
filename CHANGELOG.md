## 0.1.1

- `DocumentProcessor.pagesToPdf(List<ScannedDocument>)` — combine several
  scanned pages into one multi-page PDF (one A4 page per scan, in order). The
  multi-page counterpart to `output: ScanOutputFormat.pdf`; pass the pages you
  collected in a `ScanSession`. Each page's bytes are embedded as-is (no
  re-encode); returns null for an empty list.

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
  filters. Output as PNG, JPEG, or a single-page PDF via `ScanOutputFormat`.
  Undecodable input (and a degenerate/1px warp) returns `null` rather than
  throwing.
- `AutoCaptureAnalyzer` — pure-Dart stream analyzer that signals when a document
  has been held steady and confident long enough to auto-capture. Pipe the
  detector straight in with `bindEvents(detectStream(...))` (or `bindCorners` /
  `addEvent` for finer control) — the event distinctions are preserved.
- `DocumentProcessor.crop` caps the warp output's long side at `maxDimension`
  (default 2000px, aspect-preserving; pass `null` to warp at full resolution) so
  a near-full-frame high-megapixel photo doesn't produce a needlessly huge scan.
- Off-UI-thread crop: `crop`/`applyFilter` take a `background` flag (default
  `false`) that runs the pure-Dart warp+filter on a background isolate; the
  `DocumentScanner.scan` façade defaults it to `true`, so the simple path never
  janks the UI without the caller reaching for `Isolate.run`.
- `ScanSession` — an immutable multi-page container (add / reorder / remove).
- Plugin-free value types with value equality: `ScanInput` (with format-specific
  `bgraFrame` / `yuvFrame` frame factories), `DocumentCorners` (geometry-ordered
  corners + confidence), `ScannedDocument`, `ScanFilter`, `ScanOutputFormat`
  (`png` / `jpeg` / `pdf` constants, plus `jpegAt(quality)`).
- Example app with four flows: gallery scan, realtime overlay (detectStream +
  CornerStabilizer + AutoCaptureAnalyzer over a live camera), manual corner
  edit (drag-adjust → crop with `corners:`), and reprocess (detect once, swap
  filters live). Plain `StatefulWidget`, no state-management dependency.
