import 'package:flutter/material.dart';

import '../data/grid_lookup.dart';
import '../state/app_state.dart';
import 'barcode_screen.dart';

class GridSetupScreen extends StatefulWidget {
  const GridSetupScreen({super.key});

  @override
  State<GridSetupScreen> createState() => _GridSetupScreenState();
}

class _GridSetupScreenState extends State<GridSetupScreen> {
  final _rows = TextEditingController();
  final _cols = TextEditingController();
  String? _barcode;
  String? _status;

  @override
  void initState() {
    super.initState();
    final s = AppStateScope.read(context);
    if (s.rows != null) _rows.text = '${s.rows}';
    if (s.cols != null) _cols.text = '${s.cols}';
    _barcode = s.barcode;
  }

  @override
  void dispose() {
    _rows.dispose();
    _cols.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final code = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const BarcodeScreen()),
    );
    if (code == null || !mounted) return;
    final s = AppStateScope.read(context);
    final hit = lookupGrid(code, s.learnedGrid);
    setState(() {
      _barcode = code;
      if (hit != null) {
        _rows.text = '${hit.rows}';
        _cols.text = '${hit.cols}';
        _status = 'Known puzzle: ${hit.rows} × ${hit.cols}';
      } else {
        _status = 'Barcode $code not in table — enter rows × cols once, it will be remembered.';
      }
    });
  }

  Future<void> _save() async {
    final r = int.tryParse(_rows.text.trim());
    final c = int.tryParse(_cols.text.trim());
    if (r == null || c == null || r < 2 || c < 2) {
      setState(() => _status = 'Rows and cols must be integers ≥ 2.');
      return;
    }
    final s = AppStateScope.read(context);
    final changed = s.rows != r || s.cols != c;
    if (changed) {
      s.setGrid(r, c, code: _barcode);
    } else if (_barcode != null) {
      s.learnedGrid[_barcode!] = '$r,$c';
      s.barcode = _barcode;
    }
    await s.save();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Grid')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          OutlinedButton.icon(
            onPressed: _scan,
            icon: const Icon(Icons.qr_code_scanner),
            label: Text(_barcode == null ? 'Scan box barcode' : 'Rescan  ($_barcode)'),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _rows,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Rows', border: OutlineInputBorder()),
                ),
              ),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('×')),
              Expanded(
                child: TextField(
                  controller: _cols,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Cols', border: OutlineInputBorder()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Count pieces along one short edge and one long edge of the box art. '
            'Rows × cols must equal the piece count.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_status != null) ...[
            const SizedBox(height: 12),
            Text(_status!, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
          ],
          const SizedBox(height: 24),
          FilledButton(onPressed: _save, child: const Text('Save grid')),
          const SizedBox(height: 8),
          Text(
            'Changing the grid clears the reference image and colour model.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
