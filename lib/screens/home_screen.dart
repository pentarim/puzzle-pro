import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'grid_setup_screen.dart';
import 'presort_screen.dart';
import 'reference_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppStateScope.of(context);
    final pieces = s.hasGrid ? s.rows! * s.cols! : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Puzzle Solver')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StepTile(
            step: 1,
            title: 'Grid',
            subtitle: s.hasGrid
                ? '${s.rows} rows × ${s.cols} cols  ($pieces pieces)'
                : 'Scan barcode or enter rows × cols',
            done: s.hasGrid,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const GridSetupScreen()),
            ),
          ),
          _StepTile(
            step: 2,
            title: 'Reference image',
            subtitle: s.hasReference
                ? 'Rectified box photo ready${s.hasModel ? ' · ${s.model!.k} colour groups' : ''}'
                : 'Photograph the box and mark its corners',
            done: s.hasReference && s.hasModel,
            enabled: s.hasGrid,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ReferenceScreen()),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: s.readyToSolve
                ? () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const PresortScreen()),
                    )
                : null,
            icon: const Icon(Icons.videocam_outlined),
            label: const Text('Solve  (live overlay · freeze · tap to verify)'),
          ),
          const SizedBox(height: 32),
          Text(
            'Pieces face-up on a plain, evenly lit table, not touching. '
            'Every piece in view gets a row/col label; freeze the frame to read them at leisure, '
            'tap a piece for a dense re-check. Adjust BG threshold if pieces are missed or the table shows up.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({
    required this.step,
    required this.title,
    required this.subtitle,
    required this.done,
    required this.onTap,
    this.enabled = true,
  });

  final int step;
  final String title;
  final String subtitle;
  final bool done;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        enabled: enabled,
        leading: CircleAvatar(
          backgroundColor: done ? cs.primary : cs.surfaceContainerHighest,
          child: done ? const Icon(Icons.check) : Text('$step'),
        ),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: enabled ? onTap : null,
      ),
    );
  }
}
