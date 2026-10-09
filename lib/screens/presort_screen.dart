import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../cv/frame_packet.dart';
import '../cv/presort_worker.dart';
import '../state/app_state.dart';
import '../widgets/candidate_map.dart';
import '../widgets/cluster_map.dart';
import '../widgets/palette.dart';

enum LabelStyle { cell, cluster, both }

class PresortScreen extends StatefulWidget {
  const PresortScreen({super.key});

  @override
  State<PresortScreen> createState() => _PresortScreenState();
}

class _PresortScreenState extends State<PresortScreen> with WidgetsBindingObserver {
  CameraController? _cam;
  PresortWorker? _worker;
  StreamSubscription<PresortResult>? _resSub;
  StreamSubscription<VerifyResult>? _verSub;
  StreamSubscription<String>? _errSub;

  PresortResult? _live;
  PresortResult? _frozen; // has frozenJpeg
  bool _freezeRequested = false;
  bool _streaming = false;

  String? _error;
  bool _loadingIndex = true;
  int _rotationOverride = -1; // -1 = use sensor orientation
  int _sensorRotation = 90;
  int? _selectedCluster;
  LabelStyle _labels = LabelStyle.cell;
  double _minConf = 0.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  Future<void> _start() async {
    final s = AppStateScope.read(context);
    try {
      if (_worker == null) {
        setState(() => _loadingIndex = true);
        _worker = await PresortWorker.spawn(model: s.model!, refPath: s.refImagePath!);
        _resSub = _worker!.results.listen(_onResult);
        _verSub = _worker!.verified.listen(_onVerified);
        _errSub = _worker!.errors.listen((e) {
          if (mounted) setState(() => _error = e);
        });
        if (mounted) setState(() => _loadingIndex = false);
      }

      final cams = await availableCameras();
      final back = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      _sensorRotation = back.sensorOrientation;
      final cam = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      await cam.initialize();
      if (!mounted) {
        await cam.dispose();
        return;
      }
      _cam = cam;
      await cam.startImageStream(_onFrame);
      _streaming = true;
      setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _onFrame(CameraImage img) {
    final w = _worker;
    if (w == null || w.busy || !w.ready) return;
    if (_frozen != null) return; // frozen: ignore live frames
    final s = AppStateScope.read(context);
    final rot = _rotationOverride >= 0 ? _rotationOverride : _sensorRotation;
    final packet = packFrame(img, rot);
    if (packet == null) {
      if (_error == null) {
        setState(() => _error = 'Unsupported camera image format (${img.format.group})');
      }
      return;
    }
    final freeze = _freezeRequested;
    if (w.submit(packet, threshold: s.bgThreshold, minArea: 60, freeze: freeze) && freeze) {
      _freezeRequested = false;
    }
  }

  void _onResult(PresortResult r) {
    if (!mounted) return;
    setState(() {
      if (r.frozenJpeg != null) {
        _frozen = r;
      } else {
        _live = r;
      }
    });
  }

  void _onVerified(VerifyResult v) {
    if (!mounted || _frozen == null) return;
    final det = v.blobIndex < _frozen!.detections.length ? _frozen!.detections[v.blobIndex] : null;
    final s = AppStateScope.read(context);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _VerifySheet(
        result: v,
        detection: det,
        rows: s.rows!,
        cols: s.cols!,
        refPath: s.refImagePath!,
      ),
    );
  }

  Future<void> _stop() async {
    final cam = _cam;
    _cam = null;
    if (cam != null) {
      if (_streaming) {
        _streaming = false;
        try {
          await cam.stopImageStream();
        } catch (_) {}
      }
      await cam.dispose();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _stop();
    } else if (state == AppLifecycleState.resumed && _cam == null) {
      _start();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stop();
    _resSub?.cancel();
    _verSub?.cancel();
    _errSub?.cancel();
    _worker?.dispose();
    super.dispose();
  }

  void _cycleRotation() {
    setState(() {
      final cur = _rotationOverride >= 0 ? _rotationOverride : _sensorRotation;
      _rotationOverride = (cur + 90) % 360;
    });
  }

  void _toggleFreeze() {
    setState(() {
      if (_frozen != null) {
        _frozen = null;
      } else {
        _freezeRequested = true;
      }
    });
  }

  void _onFrozenTap(Offset norm) {
    final f = _frozen;
    if (f == null) return;
    // Smallest detection containing the tap wins (nested boxes are rare but possible).
    int? hit;
    double hitArea = double.infinity;
    for (var i = 0; i < f.detections.length; i++) {
      final d = f.detections[i];
      if (d.contains(norm.dx, norm.dy) && d.w * d.h < hitArea) {
        hit = i;
        hitArea = d.w * d.h;
      }
    }
    if (hit != null) _worker?.verify(hit);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStateScope.of(context);
    final cam = _cam;
    final model = s.model!;
    final frozen = _frozen;
    final shown = frozen ?? _live;

    return Scaffold(
      appBar: AppBar(
        title: Text(frozen == null ? 'Pre-sort · live' : 'Pre-sort · frozen'),
        actions: [
          PopupMenuButton<LabelStyle>(
            tooltip: 'Labels',
            icon: const Icon(Icons.label_outline),
            initialValue: _labels,
            onSelected: (v) => setState(() => _labels = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: LabelStyle.cell, child: Text('Row / col')),
              PopupMenuItem(value: LabelStyle.cluster, child: Text('Colour group')),
              PopupMenuItem(value: LabelStyle.both, child: Text('Both')),
            ],
          ),
          IconButton(
            tooltip: 'Rotate overlay (if it does not line up)',
            icon: const Icon(Icons.screen_rotation),
            onPressed: _cycleRotation,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                    )
                  : _loadingIndex
                      ? const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 12),
                            Text('Building cell index…'),
                          ],
                        )
                      : frozen != null
                          ? _FrozenView(
                              result: frozen,
                              painter: _OverlayPainter(
                                result: frozen,
                                selected: _selectedCluster,
                                labels: _labels,
                                minConf: _minConf,
                              ),
                              onTapNormalized: _onFrozenTap,
                            )
                          : cam == null || !cam.value.isInitialized
                              ? const CircularProgressIndicator()
                              : CameraPreview(
                                  cam,
                                  child: LayoutBuilder(
                                    builder: (_, c) => CustomPaint(
                                      size: Size(c.maxWidth, c.maxHeight),
                                      painter: _OverlayPainter(
                                        result: _live,
                                        selected: _selectedCluster,
                                        labels: _labels,
                                        minConf: _minConf,
                                      ),
                                    ),
                                  ),
                                ),
            ),
          ),
          _Legend(
            k: model.k,
            selected: _selectedCluster,
            counts: _countByCluster(shown, model.k),
            onSelect: (i) => setState(() => _selectedCluster = _selectedCluster == i ? null : i),
            onShowMap: () => _showMap(context),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              children: [
                const Text('BG'),
                Expanded(
                  child: Slider(
                    value: s.bgThreshold,
                    min: 8,
                    max: 80,
                    label: s.bgThreshold.round().toString(),
                    onChanged: (v) => setState(() => s.bgThreshold = v),
                    onChangeEnd: (_) => s.save(),
                  ),
                ),
                const Text('Conf'),
                Expanded(
                  child: Slider(
                    value: _minConf,
                    min: 0,
                    max: 0.8,
                    label: '${(_minConf * 100).round()}%',
                    onChanged: (v) => setState(() => _minConf = v),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _loadingIndex || _error != null ? null : _toggleFreeze,
                    icon: Icon(frozen == null ? Icons.pause_circle_outline : Icons.play_circle_outline),
                    label: Text(frozen == null
                        ? (_freezeRequested ? 'Freezing…' : 'Freeze')
                        : 'Resume live'),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 96,
                  child: Text(
                    shown == null ? '' : '${shown.detections.length} pcs · ${shown.millis} ms',
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<int> _countByCluster(PresortResult? r, int k) {
    final out = List<int>.filled(k, 0);
    if (r == null) return out;
    for (final d in r.detections) {
      if (d.cluster < k) out[d.cluster]++;
    }
    return out;
  }

  void _showMap(BuildContext context) {
    final s = AppStateScope.read(context);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: SizedBox(
          height: 320,
          child: ClusterMap(
            model: s.model!,
            refImagePath: s.refImagePath!,
            selected: _selectedCluster,
            onSelected: (i) => setState(() => _selectedCluster = i),
          ),
        ),
      ),
    );
  }
}

/// Zoomable frozen frame with the overlay; taps are reported in normalised coords.
class _FrozenView extends StatelessWidget {
  const _FrozenView({required this.result, required this.painter, required this.onTapNormalized});

  final PresortResult result;
  final CustomPainter painter;
  final ValueChanged<Offset> onTapNormalized;

  @override
  Widget build(BuildContext context) {
    final Uint8List jpeg = result.frozenJpeg!;
    return InteractiveViewer(
      maxScale: 8,
      child: Center(
        child: AspectRatio(
          aspectRatio: result.frameW / result.frameH,
          child: LayoutBuilder(
            builder: (_, c) => GestureDetector(
              onTapUp: (d) => onTapNormalized(
                Offset(d.localPosition.dx / c.maxWidth, d.localPosition.dy / c.maxHeight),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(jpeg, fit: BoxFit.fill, gaplessPlayback: true),
                  CustomPaint(painter: painter),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VerifySheet extends StatelessWidget {
  const _VerifySheet({
    required this.result,
    required this.detection,
    required this.rows,
    required this.cols,
    required this.refPath,
  });

  final VerifyResult result;
  final Detection? detection;
  final int rows;
  final int cols;
  final String refPath;

  @override
  Widget build(BuildContext context) {
    final cands = result.candidates;
    final d = detection;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (result.piecePng != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.memory(result.piecePng!, width: 56, height: 56, fit: BoxFit.cover),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  cands.isEmpty
                      ? 'No candidates'
                      : 'Best: R${cands.first.row + 1} C${cands.first.col + 1}'
                          '${cands.first.rot == 0 ? '' : '  ↺${cands.first.rot}°'}'
                          '   ${(cands.first.score * 100).round()}%'
                          '${d != null && d.labelled ? '\nIndex said R${d.row + 1} C${d.col + 1} (${(d.conf * 100).round()}%)' : ''}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 260,
            child: CandidateMap(rows: rows, cols: cols, refPath: refPath, candidates: cands),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < cands.length; i++)
                Chip(
                  label: Text(
                    '${i + 1}  R${cands[i].row + 1} C${cands[i].col + 1}'
                    '${cands[i].rot == 0 ? '' : ' ↺${cands[i].rot}°'}'
                    '  ${(cands[i].score * 100).round()}%',
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.k,
    required this.selected,
    required this.counts,
    required this.onSelect,
    required this.onShowMap,
  });

  final int k;
  final int? selected;
  final List<int> counts;
  final ValueChanged<int> onSelect;
  final VoidCallback onShowMap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              scrollDirection: Axis.horizontal,
              itemCount: k,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) => ClusterSwatch(
                index: i,
                count: counts[i],
                selected: selected == i,
                onTap: () => onSelect(i),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Where is this colour on the box?',
            icon: const Icon(Icons.map_outlined),
            onPressed: onShowMap,
          ),
        ],
      ),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required this.result,
    required this.selected,
    required this.labels,
    required this.minConf,
  });

  final PresortResult? result;
  final int? selected;
  final LabelStyle labels;
  final double minConf;

  @override
  void paint(Canvas canvas, Size size) {
    final r = result;
    if (r == null) return;
    final fill = Paint()..style = PaintingStyle.fill;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    // Label scale follows the frame width so text stays readable when zoomed out.
    final fs = (size.width / 34).clamp(9.0, 14.0);

    for (final d in r.detections) {
      final isSel = selected == null || selected == d.cluster;
      final c = clusterColor(d.cluster);
      final rect = Rect.fromLTWH(d.x * size.width, d.y * size.height, d.w * size.width, d.h * size.height);
      final confident = d.labelled && d.conf >= minConf;
      fill.color = c.withValues(alpha: isSel ? 0.28 : 0.05);
      stroke.color = c.withValues(alpha: isSel ? 1 : 0.2);
      final rr = RRect.fromRectAndRadius(rect, const Radius.circular(4));
      canvas.drawRRect(rr, fill);
      canvas.drawRRect(rr, stroke);
      if (!isSel) continue;

      final parts = <InlineSpan>[];
      if (labels != LabelStyle.cluster) {
        if (confident) {
          parts.add(TextSpan(
            text: 'R${d.row + 1} C${d.col + 1}',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: fs),
          ));
          parts.add(TextSpan(
            text: '${d.rot == 0 ? '' : ' ↺${d.rot}'} ${(d.conf * 100).round()}%',
            style: TextStyle(fontSize: fs * 0.8),
          ));
        } else if (d.labelled) {
          parts.add(TextSpan(text: '?', style: TextStyle(fontSize: fs)));
        }
      }
      if (labels != LabelStyle.cell) {
        parts.add(TextSpan(
          text: '${parts.isEmpty ? '' : ' · '}#${d.cluster + 1}',
          style: TextStyle(fontSize: fs, fontWeight: FontWeight.bold),
        ));
      }
      if (parts.isEmpty) continue;
      final tp = TextPainter(
        text: TextSpan(
          style: TextStyle(color: Colors.white, shadows: const [Shadow(blurRadius: 3, color: Colors.black)]),
          children: parts,
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final bg = Paint()..color = Colors.black.withValues(alpha: 0.55);
      final origin = rect.topLeft + const Offset(2, 2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(origin.dx - 2, origin.dy - 1, tp.width + 4, tp.height + 2),
          const Radius.circular(3),
        ),
        bg,
      );
      tp.paint(canvas, origin);
    }
  }

  @override
  bool shouldRepaint(_OverlayPainter old) =>
      old.result != result || old.selected != selected || old.labels != labels || old.minConf != minConf;
}
