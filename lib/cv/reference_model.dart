import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Pixels per puzzle cell in the rectified reference image.
const int kCellPx = 16;

/// Colour model of the box image: every puzzle cell has a mean Lab colour, and
/// the cells are grouped into [k] clusters. Pre-sort assigns each loose piece
/// to the nearest cluster; the legend shows where that cluster lives on the
/// reference.
class ReferenceModel {
  ReferenceModel({
    required this.rows,
    required this.cols,
    required this.k,
    required this.centersLab,
    required this.cellLabels,
    required this.cellLab,
  });

  final int rows;
  final int cols;
  final int k;

  /// k x 3, OpenCV 8-bit Lab scale (L 0..255, a/b 0..255 with 128 = neutral).
  final List<List<double>> centersLab;

  /// rows*cols cluster index per cell (row-major).
  final Uint8List cellLabels;

  /// rows*cols*3 mean Lab per cell (row-major).
  final Uint8List cellLab;

  int label(int r, int c) => cellLabels[r * cols + c];

  /// Number of cells in each cluster.
  List<int> get clusterSizes {
    final out = List<int>.filled(k, 0);
    for (final l in cellLabels) {
      out[l]++;
    }
    return out;
  }

  /// Nearest cluster for a Lab colour; a/b weighted up because lightness is
  /// the least reliable channel under table lighting.
  int nearest(double l, double a, double b) {
    var best = 0;
    var bestD = double.infinity;
    for (var i = 0; i < k; i++) {
      final c = centersLab[i];
      final dl = (l - c[0]) * 0.6;
      final da = a - c[1];
      final db = b - c[2];
      final d = dl * dl + da * da + db * db;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  /// Build from a rectified BGR reference of size (cols*kCellPx, rows*kCellPx).
  static ReferenceModel build(cv.Mat refBgr, int rows, int cols, int k) {
    final lab = cv.cvtColor(refBgr, cv.COLOR_BGR2Lab);
    // INTER_AREA down to one pixel per cell == mean Lab per cell.
    final cells = cv.resize(lab, (cols, rows), interpolation: cv.INTER_AREA);
    final cellLab = Uint8List.fromList(cells.data);
    final n = rows * cols;

    final samples = List<double>.filled(n * 3, 0);
    for (var i = 0; i < n * 3; i++) {
      samples[i] = cellLab[i].toDouble();
    }
    final data = cv.Mat.fromList(n, 3, cv.MatType.CV_32FC1, samples);
    final effectiveK = math.min(k, n);
    final (_, labels, centers) = cv.kmeans(
      data,
      effectiveK,
      cv.Mat.empty(),
      (cv.TERM_EPS + cv.TERM_COUNT, 60, 0.5),
      3,
      cv.KMEANS_PP_CENTERS,
    );

    final centersLab = List.generate(
      effectiveK,
      (i) => [
        centers.at<double>(i, 0),
        centers.at<double>(i, 1),
        centers.at<double>(i, 2),
      ],
    );
    final cellLabels = Uint8List(n);
    for (var i = 0; i < n; i++) {
      cellLabels[i] = labels.at<int>(i, 0);
    }

    lab.dispose();
    cells.dispose();
    data.dispose();
    labels.dispose();
    centers.dispose();

    return ReferenceModel(
      rows: rows,
      cols: cols,
      k: effectiveK,
      centersLab: centersLab,
      cellLabels: cellLabels,
      cellLab: cellLab,
    );
  }

  Map<String, dynamic> toJson() => {
        'rows': rows,
        'cols': cols,
        'k': k,
        'centersLab': centersLab,
        'cellLabels': base64Encode(cellLabels),
        'cellLab': base64Encode(cellLab),
      };

  static ReferenceModel fromJson(Map<String, dynamic> j) => ReferenceModel(
        rows: j['rows'] as int,
        cols: j['cols'] as int,
        k: j['k'] as int,
        centersLab: (j['centersLab'] as List)
            .map((e) => (e as List).map((v) => (v as num).toDouble()).toList())
            .toList(),
        cellLabels: base64Decode(j['cellLabels'] as String),
        cellLab: base64Decode(j['cellLab'] as String),
      );

  Future<void> saveToFile(String path) =>
      File(path).writeAsString(jsonEncode(toJson()));

  static Future<ReferenceModel?> loadFromFile(String path) async {
    final f = File(path);
    if (!await f.exists()) return null;
    try {
      return fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}
