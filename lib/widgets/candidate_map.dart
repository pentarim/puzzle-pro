import 'dart:io';

import 'package:flutter/material.dart';

import '../cv/presort_worker.dart';

/// The box art with numbered rings on the verified candidate cells.
class CandidateMap extends StatelessWidget {
  const CandidateMap({
    super.key,
    required this.rows,
    required this.cols,
    required this.refPath,
    required this.candidates,
  });

  final int rows;
  final int cols;
  final String refPath;
  final List<VerifiedCandidate> candidates;

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      maxScale: 10,
      child: Center(
        child: AspectRatio(
          aspectRatio: cols / rows,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(File(refPath), fit: BoxFit.fill),
              CustomPaint(painter: _CandidatePainter(rows: rows, cols: cols, candidates: candidates)),
            ],
          ),
        ),
      ),
    );
  }
}

class _CandidatePainter extends CustomPainter {
  _CandidatePainter({required this.rows, required this.cols, required this.candidates});

  final int rows;
  final int cols;
  final List<VerifiedCandidate> candidates;

  @override
  void paint(Canvas canvas, Size size) {
    final cw = size.width / cols;
    final ch = size.height / rows;
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.35);
    canvas.drawRect(Offset.zero & size, dim);

    for (var i = candidates.length - 1; i >= 0; i--) {
      final c = candidates[i];
      final best = i == 0;
      final center = Offset((c.col + 0.5) * cw, (c.row + 0.5) * ch);
      // Clear the cell itself so the art shows through.
      canvas.drawRect(
        Rect.fromLTWH(c.col * cw, c.row * ch, cw, ch),
        Paint()..color = (best ? Colors.cyanAccent : Colors.white).withValues(alpha: 0.35),
      );
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = best ? 2.5 : 1.2
        ..color = best ? Colors.cyanAccent : Colors.white;
      final radius = (cw < ch ? cw : ch) * (best ? 3 : 2);
      canvas.drawCircle(center, radius, ring);
      final tp = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: TextStyle(
            color: best ? Colors.cyanAccent : Colors.white,
            fontSize: best ? 13 : 11,
            fontWeight: FontWeight.bold,
            shadows: const [Shadow(blurRadius: 3, color: Colors.black)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, center + Offset(radius + 2, -tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(_CandidatePainter old) => old.candidates != candidates;
}
