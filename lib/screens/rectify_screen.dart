import 'dart:io';

import 'package:flutter/material.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../cv/reference_model.dart';

/// Tap TL, TR, BR, BL of the box art; pops with the path of the rectified PNG.
class RectifyScreen extends StatefulWidget {
  const RectifyScreen({super.key, required this.imagePath, required this.rows, required this.cols});

  final String imagePath;
  final int rows;
  final int cols;

  @override
  State<RectifyScreen> createState() => _RectifyScreenState();
}

class _RectifyScreenState extends State<RectifyScreen> {
  static const _labels = ['top-left', 'top-right', 'bottom-right', 'bottom-left'];

  String? _workPath; // downscaled copy shown on screen
  int _imgW = 0;
  int _imgH = 0;
  final List<Offset> _pts = []; // image pixel coords
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      var img = cv.imread(widget.imagePath, flags: cv.IMREAD_COLOR);
      if (img.isEmpty) throw Exception('Could not read image');
      const maxSide = 2400;
      final longest = img.cols > img.rows ? img.cols : img.rows;
      if (longest > maxSide) {
        final s = maxSide / longest;
        final small = cv.resize(img, ((img.cols * s).round(), (img.rows * s).round()), interpolation: cv.INTER_AREA);
        img.dispose();
        img = small;
      }
      final dir = await getTemporaryDirectory();
      final path = p.join(dir.path, 'box_work.jpg');
      cv.imwrite(path, img);
      // Evict any cached image at this path from a previous run.
      await FileImage(File(path)).evict();
      setState(() {
        _workPath = path;
        _imgW = img.cols;
        _imgH = img.rows;
        _busy = false;
      });
      img.dispose();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  /// Rect the image occupies inside [box] with BoxFit.contain.
  Rect _drawRect(Size box) {
    final s = (box.width / _imgW < box.height / _imgH) ? box.width / _imgW : box.height / _imgH;
    final w = _imgW * s;
    final h = _imgH * s;
    return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
  }

  void _onTap(TapDownDetails d, Size box) {
    if (_pts.length >= 4 || _imgW == 0) return;
    final r = _drawRect(box);
    if (!r.contains(d.localPosition)) return;
    final x = (d.localPosition.dx - r.left) / r.width * _imgW;
    final y = (d.localPosition.dy - r.top) / r.height * _imgH;
    setState(() => _pts.add(Offset(x, y)));
  }

  Future<void> _rectify() async {
    setState(() => _busy = true);
    try {
      final img = cv.imread(_workPath!, flags: cv.IMREAD_COLOR);
      final w = widget.cols * kCellPx;
      final h = widget.rows * kCellPx;
      final src = cv.VecPoint2f.fromList(_pts.map((o) => cv.Point2f(o.dx, o.dy)).toList());
      final dst = cv.VecPoint2f.fromList([
        cv.Point2f(0, 0),
        cv.Point2f(w.toDouble(), 0),
        cv.Point2f(w.toDouble(), h.toDouble()),
        cv.Point2f(0, h.toDouble()),
      ]);
      final m = cv.getPerspectiveTransform2f(src, dst);
      final out = cv.warpPerspective(img, m, (w, h), flags: cv.INTER_LINEAR);
      final dir = await getApplicationDocumentsDirectory();
      final path = p.join(dir.path, 'reference_rectified.png');
      cv.imwrite(path, out);
      await FileImage(File(path)).evict();
      img.dispose();
      m.dispose();
      out.dispose();
      if (mounted) Navigator.pop(context, path);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final next = _pts.length < 4 ? 'Tap the ${_labels[_pts.length]} corner' : 'All four corners set';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mark corners'),
        actions: [
          IconButton(
            tooltip: 'Undo',
            icon: const Icon(Icons.undo),
            onPressed: _pts.isEmpty ? null : () => setState(() => _pts.removeLast()),
          ),
          IconButton(
            tooltip: 'Reset',
            icon: const Icon(Icons.refresh),
            onPressed: _pts.isEmpty ? null : () => setState(_pts.clear),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_error ?? next, style: TextStyle(color: _error != null ? Colors.redAccent : null)),
          ),
          Expanded(
            child: _workPath == null
                ? const Center(child: CircularProgressIndicator())
                : LayoutBuilder(
                    builder: (context, c) {
                      final box = Size(c.maxWidth, c.maxHeight);
                      final r = _drawRect(box);
                      return GestureDetector(
                        onTapDown: (d) => _onTap(d, box),
                        child: Stack(
                          children: [
                            Positioned.fill(child: Image.file(File(_workPath!), fit: BoxFit.contain)),
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _CornerPainter(
                                  pts: _pts.map((o) => Offset(r.left + o.dx / _imgW * r.width, r.top + o.dy / _imgH * r.height)).toList(),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: _pts.length == 4 && !_busy ? _rectify : null,
              child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Rectify'),
            ),
          ),
        ],
      ),
    );
  }
}

class _CornerPainter extends CustomPainter {
  _CornerPainter({required this.pts});

  final List<Offset> pts;

  @override
  void paint(Canvas canvas, Size size) {
    final dot = Paint()..color = Colors.tealAccent;
    final line = Paint()
      ..color = Colors.tealAccent
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < pts.length; i++) {
      canvas.drawCircle(pts[i], 7, dot);
      final tp = TextPainter(
        text: TextSpan(text: '${i + 1}', style: const TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.bold)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pts[i] - Offset(tp.width / 2, tp.height / 2));
    }
    if (pts.length > 1) {
      final path = Path()..moveTo(pts[0].dx, pts[0].dy);
      for (final o in pts.skip(1)) {
        path.lineTo(o.dx, o.dy);
      }
      if (pts.length == 4) path.close();
      canvas.drawPath(path, line);
    }
  }

  @override
  bool shouldRepaint(_CornerPainter old) => old.pts != pts;
}
