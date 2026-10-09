import 'dart:io';

import 'package:flutter/material.dart';

import '../cv/reference_model.dart';
import 'palette.dart';

/// Reference image with each cell tinted by its cluster colour, plus a swatch
/// row. Tapping a swatch isolates that cluster (everything else dimmed).
class ClusterMap extends StatefulWidget {
  const ClusterMap({
    super.key,
    required this.model,
    required this.refImagePath,
    this.selected,
    this.onSelected,
  });

  final ReferenceModel model;
  final String refImagePath;
  final int? selected;
  final ValueChanged<int?>? onSelected;

  @override
  State<ClusterMap> createState() => _ClusterMapState();
}

class _ClusterMapState extends State<ClusterMap> {
  int? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.selected;
  }

  @override
  void didUpdateWidget(ClusterMap old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) _selected = widget.selected;
  }

  void _pick(int i) {
    setState(() => _selected = _selected == i ? null : i);
    widget.onSelected?.call(_selected);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.model;
    final sizes = m.clusterSizes;
    return Column(
      children: [
        Expanded(
          child: AspectRatio(
            aspectRatio: m.cols / m.rows,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.file(File(widget.refImagePath), fit: BoxFit.fill),
                CustomPaint(painter: ClusterCellPainter(model: m, selected: _selected)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: m.k,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (_, i) => ClusterSwatch(
              index: i,
              count: sizes[i],
              selected: _selected == i,
              onTap: () => _pick(i),
            ),
          ),
        ),
      ],
    );
  }
}

class ClusterSwatch extends StatelessWidget {
  const ClusterSwatch({
    super.key,
    required this.index,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final int index;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final c = clusterColor(index);
    final fg = c.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: selected ? Colors.white : Colors.transparent, width: 2),
        ),
        child: Text(
          count == null ? '${index + 1}' : '${index + 1} · $count',
          style: TextStyle(color: fg, fontWeight: FontWeight.bold, fontSize: 12),
        ),
      ),
    );
  }
}

/// Paints the cluster tint (or dims non-selected cells) over the reference.
class ClusterCellPainter extends CustomPainter {
  ClusterCellPainter({required this.model, required this.selected});

  final ReferenceModel model;
  final int? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final cw = size.width / model.cols;
    final ch = size.height / model.rows;
    final paint = Paint()..style = PaintingStyle.fill;
    // Group cells into per-cluster paths: k drawPath calls instead of rows*cols drawRect calls.
    final paths = List.generate(model.k, (_) => Path());
    for (var r = 0; r < model.rows; r++) {
      for (var c = 0; c < model.cols; c++) {
        paths[model.label(r, c)].addRect(Rect.fromLTWH(c * cw, r * ch, cw + 0.5, ch + 0.5));
      }
    }
    for (var i = 0; i < model.k; i++) {
      if (selected == null) {
        paint.color = clusterColor(i).withValues(alpha: 0.45);
      } else if (selected == i) {
        continue; // leave the selected cluster's art fully visible
      } else {
        paint.color = Colors.black.withValues(alpha: 0.8);
      }
      canvas.drawPath(paths[i], paint);
    }
    if (selected != null) {
      final outline = Paint()
        ..color = clusterColor(selected!)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawPath(paths[selected!], outline);
    }
  }

  @override
  bool shouldRepaint(ClusterCellPainter old) => old.model != model || old.selected != selected;
}
