import 'package:document_scan/document_scan.dart';
import 'package:flutter/material.dart';

/// An interactive quad overlay with four draggable corner handles, drawn over a
/// document image so the user can correct a mis-detection before cropping.
///
/// Coordinates are the package's normalized [DocumentCorners] (0..1 relative to
/// the image). The widget is meant to be laid out at exactly the image's
/// displayed size (e.g. inside a `FittedBox(BoxFit.contain) →
/// SizedBox(imageW, imageH)`), so `normalized * size` maps straight to local
/// pixels with no letterbox math. A pan grabs the nearest handle and moves it;
/// [onCornerMoved] reports the new normalized position by index
/// (0 = TL, 1 = TR, 2 = BR, 3 = BL).
///
/// Self-contained: no app theme, plain inline [Colors].
class DraggableCornerOverlay extends StatefulWidget {
  const DraggableCornerOverlay({
    required this.corners,
    required this.onCornerMoved,
    super.key,
  });

  final DocumentCorners corners;
  final void Function(int index, ({double x, double y}) point) onCornerMoved;

  @override
  State<DraggableCornerOverlay> createState() => _DraggableCornerOverlayState();
}

class _DraggableCornerOverlayState extends State<DraggableCornerOverlay> {
  // A teal accent that reads over both light document paper and dark scenes.
  static const _stroke = Color(0xFF1DE9B6);
  static const _fill = Color(0x221DE9B6);
  static const _handle = Color(0xFF1DE9B6);

  // Which handle is being dragged (null when idle). Locked on pan-down so the
  // finger doesn't jump between handles mid-drag.
  int? _activeHandle;
  Size _size = Size.zero;

  // Handles are visually ~10px but grabbable within a larger radius for touch.
  static const double _hitRadius = 32;

  List<({double x, double y})> get _points => [
    widget.corners.topLeft,
    widget.corners.topRight,
    widget.corners.bottomRight,
    widget.corners.bottomLeft,
  ];

  Offset _toLocal(({double x, double y}) p) =>
      Offset(p.x * _size.width, p.y * _size.height);

  void _onPanStart(DragStartDetails d) {
    // Grab the nearest handle within the hit radius.
    var nearest = -1;
    var nearestDist = _hitRadius;
    final pts = _points;
    for (var i = 0; i < 4; i++) {
      final dist = (d.localPosition - _toLocal(pts[i])).distance;
      if (dist < nearestDist) {
        nearest = i;
        nearestDist = dist;
      }
    }
    setState(() => _activeHandle = nearest >= 0 ? nearest : null);
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final handle = _activeHandle;
    if (handle == null || _size.isEmpty) return;
    // Clamp to the image bounds so a corner can't be dragged off-image.
    widget.onCornerMoved(handle, (
      x: (d.localPosition.dx / _size.width).clamp(0.0, 1.0),
      y: (d.localPosition.dy / _size.height).clamp(0.0, 1.0),
    ));
  }

  void _onPanEnd(DragEndDetails _) => setState(() => _activeHandle = null);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        return GestureDetector(
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          child: CustomPaint(
            size: _size,
            painter: _CornerPainter(
              corners: widget.corners,
              stroke: _stroke,
              fill: _fill,
              handle: _handle,
              active: _activeHandle,
            ),
          ),
        );
      },
    );
  }
}

class _CornerPainter extends CustomPainter {
  _CornerPainter({
    required this.corners,
    required Color stroke,
    required Color fill,
    required this.handle,
    required this.active,
  }) : _stroke = Paint()
         ..color = stroke
         ..style = PaintingStyle.stroke
         ..strokeWidth = 2.6,
       _fill = Paint()
         ..color = fill
         ..style = PaintingStyle.fill;

  final DocumentCorners corners;
  final Color handle;
  final int? active;
  final Paint _stroke;
  final Paint _fill;

  @override
  void paint(Canvas canvas, Size size) {
    Offset at(({double x, double y}) p) =>
        Offset(p.x * size.width, p.y * size.height);
    final tl = at(corners.topLeft);
    final tr = at(corners.topRight);
    final br = at(corners.bottomRight);
    final bl = at(corners.bottomLeft);

    final path = Path()
      ..moveTo(tl.dx, tl.dy)
      ..lineTo(tr.dx, tr.dy)
      ..lineTo(br.dx, br.dy)
      ..lineTo(bl.dx, bl.dy)
      ..close();
    canvas.drawPath(path, _fill);
    canvas.drawPath(path, _stroke);

    final handles = [tl, tr, br, bl];
    for (var i = 0; i < 4; i++) {
      final isActive = i == active;
      // White ring + accent fill; the active handle is larger for feedback.
      final r = isActive ? 13.0 : 10.0;
      canvas.drawCircle(handles[i], r + 2, Paint()..color = Colors.white);
      canvas.drawCircle(handles[i], r, Paint()..color = handle);
    }
  }

  @override
  bool shouldRepaint(covariant _CornerPainter old) =>
      old.corners != corners || old.active != active;
}
