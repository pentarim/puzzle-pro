import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../cv/reference_model.dart';
import '../state/app_state.dart';
import '../widgets/cluster_map.dart';
import 'rectify_screen.dart';

class ReferenceScreen extends StatefulWidget {
  const ReferenceScreen({super.key});

  @override
  State<ReferenceScreen> createState() => _ReferenceScreenState();
}

class _ReferenceScreenState extends State<ReferenceScreen> {
  final _picker = ImagePicker();
  bool _working = false;
  String? _error;

  Future<void> _capture(ImageSource source) async {
    final s = AppStateScope.read(context);
    final x = await _picker.pickImage(source: source, imageQuality: 95, maxWidth: 3000);
    if (x == null || !mounted) return;

    final rectifiedPath = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => RectifyScreen(imagePath: x.path, rows: s.rows!, cols: s.cols!),
      ),
    );
    if (rectifiedPath == null || !mounted) return;
    await _buildModel(rectifiedPath);
  }

  Future<void> _buildModel(String rectifiedPath) async {
    final s = AppStateScope.read(context);
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final ref = cv.imread(rectifiedPath, flags: cv.IMREAD_COLOR);
      final model = ReferenceModel.build(ref, s.rows!, s.cols!, s.k);
      ref.dispose();
      final dir = await getApplicationDocumentsDirectory();
      final modelPath = p.join(dir.path, 'reference_model.json');
      await model.saveToFile(modelPath);
      s.refImagePath = rectifiedPath;
      s.modelPath = modelPath;
      s.model = model;
      await s.save();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _rebuild() async {
    final s = AppStateScope.read(context);
    if (s.refImagePath != null) await _buildModel(s.refImagePath!);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStateScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Reference image')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (s.hasReference) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(File(s.refImagePath!), fit: BoxFit.contain),
            ),
            const SizedBox(height: 12),
            if (s.hasModel) ...[
              Text('Colour groups (k = ${s.k})', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              SizedBox(
                height: 220,
                child: ClusterMap(model: s.model!, refImagePath: s.refImagePath!),
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                const Text('k'),
                Expanded(
                  child: Slider(
                    value: s.k.toDouble(),
                    min: 4,
                    max: 24,
                    divisions: 20,
                    label: '${s.k}',
                    onChanged: _working ? null : (v) => setState(() => s.k = v.round()),
                    onChangeEnd: (_) => _rebuild(),
                  ),
                ),
                Text('${s.k}'),
              ],
            ),
            const SizedBox(height: 8),
          ],
          if (_working) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _working ? null : () => _capture(ImageSource.camera),
            icon: const Icon(Icons.photo_camera),
            label: Text(s.hasReference ? 'Re-photograph box' : 'Photograph box'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _working ? null : () => _capture(ImageSource.gallery),
            icon: const Icon(Icons.photo_library),
            label: const Text('Pick from gallery'),
          ),
          const SizedBox(height: 16),
          Text(
            'Shoot the box art as flat and evenly lit as you can, then tap its four corners. '
            'Perspective is corrected automatically.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
