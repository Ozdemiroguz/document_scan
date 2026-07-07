import 'package:document_scan_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('home menu lists the four demo flows', (tester) async {
    await tester.pumpWidget(const DocumentScanExampleApp());

    expect(find.text('Gallery scan'), findsOneWidget);
    expect(find.text('Realtime overlay'), findsOneWidget);
    expect(find.text('Manual corner edit'), findsOneWidget);
    expect(find.text('Reprocess with filter'), findsOneWidget);
    // Each demo row is a tappable ListTile.
    expect(find.byType(ListTile), findsNWidgets(4));
  });
}
