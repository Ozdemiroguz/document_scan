# Roadmap

This is a living document. `document_scan` is actively maintained — small, regular
releases over big, rare ones. Dates are targets, not promises, and priorities shift
with real-world feedback. Have a request? [Open an issue](https://github.com/Ozdemiroguz/document_scan/issues).

## Release cadence

A patch or minor release roughly every few weeks while active — Flutter-SDK
compatibility bumps, bug fixes, docs, and the items below. Issues get a first
response quickly; the package won't go silent for months.

## Shipped

- **0.2.1** — Sharper positioning, inline dartdoc examples on the core methods,
  discoverability (topics + description), doc-link fix.
- **0.2.0** — `DetectionSensitivity` (strict / balanced / lenient), a `detectStream`
  rate cap (`minInterval`), a multi-strategy Android detection pipeline for better
  recall on low-contrast documents, and an expanded example app (camera capture,
  shared result screen, multi-page PDF export).
- **0.1.x** — Corner detection (iOS Apple Vision + Android OpenCV), pure-Dart
  perspective correction + filters, live-frame `detectStream`, manual corner
  adjustment, multi-page `ScanSession`, PNG / JPEG / single-page PDF output.

## Planned — next

- **Docs polish** — DRY the dartdoc with `{@template}`/`{@macro}`, and link the
  example app directly from the API reference.
- **Android low-contrast recall** — keep tuning the multi-strategy pipeline for the
  hardest case (a pale document on a light surface), where classical CV is weakest.
- **A getting-started tutorial** — a step-by-step guide to building a scanner UI on
  top of the package, beyond the API docs.

## Under consideration (feedback wanted)

These aren't committed — they depend on whether people actually want them. Weigh in
on an issue if one matters to you.

- **More filters** — additional post-crop looks beyond the current set.
- **A brightness/contrast auto-tune** on the enhance filter.
- **Configurable output DPI** for the multi-page PDF export.

## Explicitly *not* planned

Naming these keeps the package's scope honest:

- **A bundled ML model or OCR** — detection stays native-light (Apple Vision /
  OpenCV). If you need OCR, run it on the returned bytes with a package built for it.
- **A fullscreen scanner UI** — the whole point is that the UI is yours. `document_scan`
  returns data (corners + pixels), not a screen.
- **Owning the camera** — you feed it frames or files from your own capture layer.

## Support

The core is, and stays, free and open source. If you'd like to support continued
development, a sponsorship option is coming soon.
