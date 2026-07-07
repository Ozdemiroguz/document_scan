import 'dart:isolate';

import 'package:document_scan/document_scan.dart';

/// Runs the CPU-heavy crop (perspective warp + filter + encode) on a background
/// isolate so the UI thread stays responsive during processing.
///
/// Why this matters: `DocumentProcessor.crop` is pure Dart — the warp samples
/// every output pixel — so calling it directly blocks the UI while it runs. The
/// package deliberately does *not* spawn its own isolate (it leaves threading to
/// you, so it composes with whatever concurrency model your app uses); this
/// helper shows the one-liner you'd add. Detection is not offloaded: it goes
/// through a platform channel (native, already off the UI thread) and a
/// `MethodChannel` isn't available inside `Isolate.run`.
///
/// [DocumentCorners], [ScanFilter] and [ScanOutputFormat] are all sendable
/// (plain value types), and a `ScanInput.file` only carries a path, so the whole
/// call closes over sendable data and runs cleanly in the spawned isolate.
Future<ScannedDocument?> cropInIsolate(
  String imagePath,
  DocumentCorners corners, {
  ScanFilter filter = ScanFilter.enhance,
  ScanOutputFormat output = ScanOutputFormat.png,
}) {
  return Isolate.run(
    () => const DocumentProcessor().crop(
      ScanInput.file(imagePath),
      corners,
      filter: filter,
      output: output,
    ),
  );
}
