import 'package:document_scan_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every demo flow the home menu offers, in order. Kept as one list so adding a
/// screen without wiring it into the menu (or the reverse) fails here — the
/// count and the titles can't drift apart the way they did when the camera
/// capture flow landed.
const _demoTitles = <String>[
  'Gallery scan',
  'Camera capture',
  'Realtime overlay',
  'Manual corner edit',
  'Reprocess with filter',
  'Multi-page session',
];

void main() {
  testWidgets('home menu lists every demo flow', (tester) async {
    await tester.pumpWidget(const DocumentScanExampleApp());

    for (final title in _demoTitles) {
      expect(find.text(title), findsOneWidget, reason: 'missing demo: $title');
    }
    // Each demo row is a tappable ListTile, and there are no extras.
    expect(find.byType(ListTile), findsNWidgets(_demoTitles.length));
  });
}
