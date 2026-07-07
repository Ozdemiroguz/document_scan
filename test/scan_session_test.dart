import 'dart:typed_data';

import 'package:document_scan/document_scan.dart';
import 'package:flutter_test/flutter_test.dart';

ScannedPage page(int tag) => ScannedPage(
      document: ScannedDocument(
        bytes: Uint8List.fromList([tag]),
        width: tag,
        height: tag,
      ),
    );

/// Reads back each page's width as a stable identity tag.
List<int> tags(ScanSession s) => s.pages.map((p) => p.document.width).toList();

void main() {
  test('starts empty', () {
    const s = ScanSession();
    expect(s.isEmpty, isTrue);
    expect(s.length, 0);
  });

  test('add appends and is immutable (returns a new session)', () {
    const s0 = ScanSession();
    final s1 = s0.add(page(1));
    final s2 = s1.add(page(2));
    expect(tags(s0), isEmpty); // original untouched
    expect(tags(s1), [1]);
    expect(tags(s2), [1, 2]);
    expect(s2.isNotEmpty, isTrue);
  });

  test('removeAt drops the right page; out-of-range is a no-op', () {
    final s = const ScanSession().add(page(1)).add(page(2)).add(page(3));
    expect(tags(s.removeAt(1)), [1, 3]);
    expect(tags(s.removeAt(9)), [1, 2, 3]); // no-op
    expect(tags(s.removeAt(-1)), [1, 2, 3]); // no-op
  });

  test('replaceAt swaps a page in place', () {
    final s = const ScanSession().add(page(1)).add(page(2));
    final r = s.replaceAt(0, page(9));
    expect(tags(r), [9, 2]);
    expect(tags(s), [1, 2]); // original untouched
  });

  group('reorder (ReorderableListView convention)', () {
    final base = const ScanSession().add(page(1)).add(page(2)).add(page(3));

    test('move first to last', () {
      // Drag index 0 to the end: Flutter passes newIndex = length (3).
      expect(tags(base.reorder(0, 3)), [2, 3, 1]);
    });

    test('move last to first', () {
      expect(tags(base.reorder(2, 0)), [3, 1, 2]);
    });

    test('move middle forward one', () {
      expect(tags(base.reorder(1, 2)), [1, 2, 3]); // no visible change (adjacent)
    });

    test('same index is a no-op', () {
      expect(tags(base.reorder(1, 1)), [1, 2, 3]);
    });

    test('empty session reorder is safe', () {
      expect(const ScanSession().reorder(0, 1).isEmpty, isTrue);
    });
  });

  test('clear empties the session', () {
    final s = const ScanSession().add(page(1)).add(page(2));
    expect(s.clear().isEmpty, isTrue);
  });

  test('ScannedPage.copyWith replaces fields', () {
    final p = page(1);
    final corners = DocumentCorners.fromUnordered([
      (x: 0.0, y: 0.0),
      (x: 1.0, y: 0.0),
      (x: 1.0, y: 1.0),
      (x: 0.0, y: 1.0),
    ]);
    final p2 = p.copyWith(corners: corners);
    expect(p2.corners, isNotNull);
    expect(p2.document.width, 1); // document preserved
  });

  group('value equality', () {
    test('ScannedDocument compares by dimensions + byte content', () {
      final a = ScannedDocument(
        bytes: Uint8List.fromList([1, 2, 3]),
        width: 10,
        height: 20,
      );
      final b = ScannedDocument(
        bytes: Uint8List.fromList([1, 2, 3]),
        width: 10,
        height: 20,
      );
      final c = ScannedDocument(
        bytes: Uint8List.fromList([1, 2, 4]), // different last byte
        width: 10,
        height: 20,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('ScannedPage compares document + corners', () {
      expect(page(1), equals(page(1)));
      expect(page(1), isNot(equals(page(2))));
    });

    test('ScanSession compares pages in order', () {
      final s1 = const ScanSession().add(page(1)).add(page(2));
      final s2 = const ScanSession().add(page(1)).add(page(2));
      final s3 = const ScanSession().add(page(2)).add(page(1)); // reordered
      expect(s1, equals(s2));
      expect(s1.hashCode, s2.hashCode);
      expect(s1, isNot(equals(s3)));
    });
  });
}
