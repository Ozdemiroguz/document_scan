import 'package:flutter/foundation.dart';

import '../types/document_corners.dart';
import '../types/scanned_document.dart';

/// One page of a multi-page scan: the perspective-corrected [document] plus the
/// [corners] it was cropped from (kept so a page can be re-cropped or edited).
class ScannedPage {
  const ScannedPage({required this.document, this.corners});

  /// The processed, upright page image.
  final ScannedDocument document;

  /// The corners the page was cropped from, if known — useful for a re-crop or
  /// a manual corner edit later.
  final DocumentCorners? corners;

  ScannedPage copyWith({ScannedDocument? document, DocumentCorners? corners}) {
    return ScannedPage(
      document: document ?? this.document,
      corners: corners ?? this.corners,
    );
  }

  @override
  String toString() => 'ScannedPage(${document.width}x${document.height})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScannedPage &&
          other.document == document &&
          other.corners == corners;

  @override
  int get hashCode => Object.hash(document, corners);
}

/// An immutable, framework-free collection of scanned [pages] in order.
///
/// A real document is several pages, so a scanner needs a place to accumulate
/// and reorder them before export. This is a plain value type — no camera, no
/// UI, no `ChangeNotifier` — so it works in any state-management approach: each
/// mutation returns a new [ScanSession], which you store however you like
/// (setState, a controller, a Bloc, …). Feed the ordered [pages] straight to
/// PDF or image export.
class ScanSession {
  const ScanSession({this.pages = const []});

  /// The pages, in the order they'll be exported.
  final List<ScannedPage> pages;

  /// Number of pages in the session.
  int get length => pages.length;

  /// Whether the session has no pages yet.
  bool get isEmpty => pages.isEmpty;

  /// Whether the session has at least one page.
  bool get isNotEmpty => pages.isNotEmpty;

  /// Returns a new session with [page] appended.
  ScanSession add(ScannedPage page) {
    return ScanSession(pages: [...pages, page]);
  }

  /// Returns a new session with the page at [index] removed. A no-op (returns an
  /// equivalent session) if [index] is out of range.
  ScanSession removeAt(int index) {
    if (index < 0 || index >= pages.length) return this;
    final next = [...pages]..removeAt(index);
    return ScanSession(pages: next);
  }

  /// Returns a new session with the page at [index] replaced by [page].
  ScanSession replaceAt(int index, ScannedPage page) {
    if (index < 0 || index >= pages.length) return this;
    final next = [...pages];
    next[index] = page;
    return ScanSession(pages: next);
  }

  /// Returns a new session with the page moved from [oldIndex] to [newIndex],
  /// following the `ReorderableListView` convention: [newIndex] is the target
  /// slot computed **before** removal, so it ranges 0..length (length means
  /// "move to the end"). Out-of-range indices are clamped.
  ScanSession reorder(int oldIndex, int newIndex) {
    if (pages.isEmpty) return this;
    final from = oldIndex.clamp(0, pages.length - 1);
    var to = newIndex.clamp(0, pages.length); // 0..length (pre-removal target)
    // After removing `from`, a target past it shifts left by one.
    if (to > from) to -= 1;
    if (to == from) return this;
    final next = [...pages];
    final moved = next.removeAt(from);
    next.insert(to, moved);
    return ScanSession(pages: next);
  }

  /// Returns an empty session.
  ScanSession clear() => const ScanSession();

  @override
  String toString() => 'ScanSession(${pages.length} pages)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScanSession && listEquals(other.pages, pages);

  @override
  int get hashCode => Object.hashAll(pages);
}
