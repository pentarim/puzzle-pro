import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../cv/reference_model.dart';

/// Everything the app needs to persist between launches.
class AppState extends ChangeNotifier {
  AppState._(this._prefs);

  final SharedPreferences _prefs;

  int? rows;
  int? cols;
  String? barcode;

  /// Rectified reference image (BGR PNG, cols*cell x rows*cell).
  String? refImagePath;

  /// Serialised [ReferenceModel].
  String? modelPath;
  ReferenceModel? model;

  /// Number of colour clusters for pre-sort.
  int k = 10;

  /// Lab distance from background above which a pixel counts as "piece".
  double bgThreshold = 28;

  /// Barcodes the user has already resolved manually: barcode -> "rows,cols".
  Map<String, String> learnedGrid = {};

  static const _kRows = 'rows';
  static const _kCols = 'cols';
  static const _kBarcode = 'barcode';
  static const _kRef = 'refImagePath';
  static const _kModel = 'modelPath';
  static const _kK = 'k';
  static const _kThr = 'bgThreshold';
  static const _kLearned = 'learnedGrid';

  static Future<AppState> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = AppState._(prefs);
    s.rows = prefs.getInt(_kRows);
    s.cols = prefs.getInt(_kCols);
    s.barcode = prefs.getString(_kBarcode);
    s.refImagePath = prefs.getString(_kRef);
    s.modelPath = prefs.getString(_kModel);
    s.k = prefs.getInt(_kK) ?? 10;
    s.bgThreshold = prefs.getDouble(_kThr) ?? 28;
    final learned = prefs.getString(_kLearned);
    if (learned != null) {
      s.learnedGrid = Map<String, String>.from(jsonDecode(learned) as Map);
    }
    if (s.modelPath != null) {
      s.model = await ReferenceModel.loadFromFile(s.modelPath!);
    }
    return s;
  }

  Future<void> save() async {
    if (rows != null) await _prefs.setInt(_kRows, rows!);
    if (cols != null) await _prefs.setInt(_kCols, cols!);
    if (barcode != null) await _prefs.setString(_kBarcode, barcode!);
    if (refImagePath != null) await _prefs.setString(_kRef, refImagePath!);
    if (modelPath != null) await _prefs.setString(_kModel, modelPath!);
    await _prefs.setInt(_kK, k);
    await _prefs.setDouble(_kThr, bgThreshold);
    await _prefs.setString(_kLearned, jsonEncode(learnedGrid));
    notifyListeners();
  }

  bool get hasGrid => rows != null && cols != null;
  bool get hasReference => refImagePath != null;
  bool get hasModel => model != null;
  bool get readyToSolve => hasGrid && hasReference && hasModel;

  void setGrid(int r, int c, {String? code}) {
    rows = r;
    cols = c;
    if (code != null && code.isNotEmpty) {
      barcode = code;
      learnedGrid[code] = '$r,$c';
    }
    // Grid change invalidates the reference & model.
    refImagePath = null;
    modelPath = null;
    model = null;
  }
}

class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({super.key, required super.notifier, required super.child});

  /// Subscribes the caller to changes (use in build).
  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppStateScope>();
    assert(scope != null, 'AppStateScope missing');
    return scope!.notifier!;
  }

  /// One-off access without subscribing (safe in initState / callbacks).
  static AppState read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppStateScope>();
    assert(scope != null, 'AppStateScope missing');
    return scope!.notifier!;
  }
}
