import 'package:flutter/material.dart';

import 'screens/gallery_scan_screen.dart';
import 'screens/manual_edit_screen.dart';
import 'screens/realtime_scan_screen.dart';
import 'screens/reprocess_screen.dart';

void main() => runApp(const DocumentScanExampleApp());

/// A multi-flow tour of the `document_scan` package. Each menu entry opens a
/// self-contained screen that exercises a different slice of the API:
///
/// * **Gallery scan** — the one-call [DocumentScanner.scan] façade.
/// * **Realtime overlay** — [DocumentDetector.detectStream] with corner
///   stabilization + an [AutoCaptureAnalyzer], drawn over a live camera preview.
/// * **Manual corner edit** — detect, drag-adjust the quad, then crop with the
///   user's corners.
/// * **Reprocess with filter** — detect+crop once, then re-filter the same scan
///   cheaply through [DocumentProcessor].
class DocumentScanExampleApp extends StatelessWidget {
  const DocumentScanExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'document_scan example',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

/// The launcher menu. Plain [StatelessWidget] + [Navigator] — no state-mgmt
/// library, to keep the example about the package rather than the plumbing.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final demos = <_Demo>[
      const _Demo(
        title: 'Gallery scan',
        subtitle: 'One call: pick a photo → DocumentScanner.scan → clean scan.',
        icon: Icons.photo_library_outlined,
        builder: GalleryScanScreen.new,
      ),
      const _Demo(
        title: 'Realtime overlay',
        subtitle:
            'Live camera → detectStream with a CornerStabilizer + '
            'AutoCaptureAnalyzer, drawn as a quad overlay.',
        icon: Icons.videocam_outlined,
        builder: RealtimeScanScreen.new,
      ),
      const _Demo(
        title: 'Manual corner edit',
        subtitle:
            'Detect the corners, drag them to correct, then crop with your '
            'own corners.',
        icon: Icons.crop_free,
        builder: ManualEditScreen.new,
      ),
      const _Demo(
        title: 'Reprocess with filter',
        subtitle:
            'Detect + crop once, then swap filters live — only the filter '
            're-runs, not detection.',
        icon: Icons.tune,
        builder: ReprocessScreen.new,
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('document_scan demos')),
      body: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: demos.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final demo = demos[i];
          return ListTile(
            leading: CircleAvatar(child: Icon(demo.icon)),
            title: Text(demo.title),
            subtitle: Text(demo.subtitle),
            isThreeLine: true,
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => demo.builder()),
            ),
          );
        },
      ),
    );
  }
}

class _Demo {
  const _Demo({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.builder,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Widget Function() builder;
}
