## 0.3.0

Three behaviour fixes. No API breaks — every existing call still compiles — but
scans, filters and auto-capture signals change, so this is a minor bump rather
than a patch.

- **The perspective correction is now an actual perspective correction.**
  `DocumentProcessor.crop` mapped the output to the source with a four-corner
  *bilinear* blend, which pins the corners exactly and gets everything between
  them wrong: it has no perspective division, so the foreshortening a tilted
  page introduces was never undone, only stretched out linearly. On a page
  photographed at ~50°, ten equal bands came back on a ramp — 32 px to 54 px
  against an ideal 42.5 — bending text spacing and hurting OCR. Replaced with
  the projective transform (homography) this always should have been; the same
  scene now recovers 42–43 px bands. Degenerate quads fall back to the old
  bilinear map, and non-finite coordinates are clamped, so a bad quad still
  yields a bad crop rather than a crash.
- **`ScanFilter.blackWhite` now actually binarizes.** It applied a contrast +
  brightness boost and left a full range of greys behind, contradicting both its
  own dartdoc and `enhance`'s ("without the hard binarization of
  `blackWhite`"). It now thresholds every pixel to ink or paper with Otsu's
  method — one global cut, the fast, crisp choice on an evenly-lit page, with
  `magicColor` still the per-region option for shadows and gradients. If you
  were on 0.2.x and *wanted* what `blackWhite` actually did, switch to
  `ScanFilter.enhance`: grayscale plus a contrast boost, which is the same
  family of result and keeps its greys.
- **Auto-capture fires once per hold again.** While latched,
  `AutoCaptureAnalyzer.addEvent` echoed `ready` back on every `DetectionSkipped`,
  so `shouldCapture` re-fired on dropped frames — and `detectStream(minInterval:)`
  makes dropped frames the common case, turning one steady hold into a burst of
  captures. A skip now reports `detecting` (or `searching` when nothing has been
  seen) while still holding the accumulated steadiness.
- `DocumentScanner.detectCorners` takes a `sensitivity` argument, like `scan`,
  `detect` and `detectStream` already did. It defaults to `balanced` — for
  corners you're about to *show*, a wrong quad the user must drag back is worse
  than no quad.
- Example: the home-menu test asserted five demo rows and has been failing since
  the camera-capture flow made it six. It now checks the titles themselves, so a
  new screen that isn't wired into the menu fails loudly instead of silently.
- Docs: corrected the README filter table (`magicColor` was described as
  "brightened, saturated color"), the `_orderByAngle` tie-break description, the
  claim that `DocumentProcessor` "works anywhere Flutter runs" (`background:
  true` needs `Isolate.run`, which web lacks), and noted that a background crop
  copies a `BytesScanInput`'s buffer while a `FileScanInput` carries only a path.

## 0.2.3

- Declare the logo under `screenshots:` so it renders as the pub.dev listing
  thumbnail (0.2.2 shipped the image but didn't register it).

## 0.2.2

Visual identity only — no API or behaviour changes.

- Add a package logo, shown as the pub.dev listing thumbnail.
- Add a landscape cover image for link/social previews.

## 0.2.1

Docs & discoverability only — no API or behaviour changes.

- Add runnable code examples to the dartdoc of `DocumentScanner.scan`,
  `DocumentDetector.detect`, and `DocumentDetector.detectStream`, so the API
  reference stands on its own without jumping back to the README.
- Sharpen the package description and README to lead with what sets it apart —
  a headless engine that hands you the document's corner coordinates, offline,
  rather than a fullscreen scanner UI.
- Retune `topics` for discovery.
- Fix a broken link in the API reference: a dartdoc reference pointed at
  `VNRectangleObservation`, an iOS-only Swift type with no Dart symbol, so it
  rendered as a dead link on the `confidence` docs. Now plain code text.

## 0.2.0

- `DetectionSensitivity` (`strict` / `balanced` / `lenient`) — a portable control
  over how eagerly a rectangle counts as a document, on `detect`, `detectStream`,
  and `scan`. The level is the contract; each native engine maps it to its own
  thresholds (Vision confidence + min-size on iOS; contour-area, adaptive-Canny
  band, corner-angle, and score floor on Android). Context defaults:
  `detectStream` → `strict`, `scan` → `lenient`, `detect` → `balanced`.
- `detectStream(minInterval:)` — cap the detection rate so a 30–60 fps camera
  doesn't run native detection on every frame (which heats the device without a
  smoother overlay). Frames that arrive too soon are dropped as `DetectionSkipped`
  before reaching the engine.
- Android detection reworked for recall on solid / low-contrast documents: a
  multi-strategy candidate generator (adaptive Canny + close, adaptive-threshold
  silhouette, Triangle auto-threshold) pooled through `convexHull` + an
  `approxPolyDP` epsilon sweep, then scored by rectangularity + right-angle-ness
  instead of taking the first/largest quad. `RETR_EXTERNAL`, a max-area cap, and a
  per-level score floor reject the whole-frame false capture and background
  clutter that a single Canny pass either missed or over-triggered on.
- Example: a camera-capture flow (live preview → shutter → scan → result), the
  realtime flow now grabs a full-resolution still on auto-capture and shows the
  scanned result (with an auto/manual toggle), a shared pinch-zoomable result
  screen, tap-to-inspect multi-page thumbnails, and a working PDF export via the
  system share sheet.

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
