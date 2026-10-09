import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = await AppState.load();
  runApp(PuzzleApp(state: state));
}

class PuzzleApp extends StatelessWidget {
  const PuzzleApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppStateScope(
      notifier: state,
      child: MaterialApp(
        title: 'Puzzle Solver',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorSchemeSeed: Colors.teal,
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
