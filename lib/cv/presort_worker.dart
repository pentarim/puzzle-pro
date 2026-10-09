import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'frame_packet.dart';
import 'reference_model.dart';
import 'segmentation.dart';

/// Width the live frame is downscaled to before segmentation.
const int kWorkWidth = 320;

/// Descriptor grid per cell (g x g x 3 Lab values).
const int kDescGrid = 4;
const int kDescLen = kDescGrid * kDescGrid * 3;

/// Weight on L in descriptors and cluster distance (lighting varies most in L).
const double kLWeight = 0.6;

/// Neighbours returned per query by the index search.
const int kKnn = 6;

/// Fraction trimmed from each side of a blob's bounding box before describing
/// it (drops most of the tabs/blanks, which are not in the box art).
const double kInset = 0.2;

/// One detected piece, normalised to the display-oriented frame (0..1).
class Detection {
  Detection({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.cluster,
    required this.row,
    required this.col,
    required this.rot,
    required this.conf,
  });

  final double x, y, w, h;
  final int cluster;

  /// 0-based best cell, or -1 when the blob was too small to describe.
  final int row, col;

  /// Degrees to turn the piece counter-clockwise to match the box art.
  final int rot;

  /// 0..1 ratio-test confidence in the best cell.
  final double conf;

  bool get labelled => row >= 0;

  bool contains(double px, double py) => px >= x && px <= x + w && py >= y && py <= y + h;
}

class PresortResult {
  PresortResult({
    required this.detections,
    required this.frameW,
    required this.frameH,
    required this.millis,
    this.frozenJpeg,
  });

  final List<Detection> detections;
  final int frameW;
  final int frameH;
  final int millis;

  /// Set when the frame was processed with freeze=true.
  final Uint8List? frozenJpeg;
}

class VerifiedCandidate {
  VerifiedCandidate(this.row, this.col, this.rot, this.score);

  final int row, col, rot;
  final double score; // TM_CCOEFF_NORMED, -1..1
}

class VerifyResult {
  VerifyResult(this.blobIndex, this.candidates, this.piecePng);

  final int blobIndex;
  final List<VerifiedCandidate> candidates;
  final Uint8List? piecePng;
}

/// Runs segmentation, cluster assignment and cell lookup off the UI isolate.
///
/// Frames are dropped while one is in flight, so the UI never queues up.
class PresortWorker {
  PresortWorker._();

  Isolate? _isolate;
  SendPort? _toWorker;
  final _fromWorker = ReceivePort();
  final _results = StreamController<PresortResult>.broadcast();
  final _verified = StreamController<VerifyResult>.broadcast();
  final _errors = StreamController<String>.broadcast();
  bool _busy = false;
  bool _ready = false;

  Stream<PresortResult> get results => _results.stream;
  Stream<VerifyResult> get verified => _verified.stream;
  Stream<String> get errors => _errors.stream;
  bool get busy => _busy;
  bool get ready => _ready;

  static Future<PresortWorker> spawn({
    required ReferenceModel model,
    required String refPath,
  }) async {
    final w = PresortWorker._();
    final port = Completer<SendPort>();
    final ready = Completer<void>();
    w._fromWorker.listen((msg) {
      if (msg is SendPort) {
        port.complete(msg);
        return;
      }
      if (msg is! Map) return;
      switch (msg['type']) {
        case 'ready':
          w._ready = true;
          if (!ready.isCompleted) ready.complete();
        case 'result':
          w._busy = false;
          w._results.add(_decodeResult(msg));
        case 'verified':
          w._verified.add(_decodeVerify(msg));
        case 'error':
          w._busy = false;
          final e = msg['error'] as String;
          if (!ready.isCompleted) {
            ready.completeError(e);
          } else {
            w._errors.add(e);
          }
      }
    });
    w._isolate = await Isolate.spawn(_entry, w._fromWorker.sendPort);
    w._toWorker = await port.future;
    w._toWorker!.send({
      'type': 'init',
      'refPath': refPath,
      'rows': model.rows,
      'cols': model.cols,
      'k': model.k,
      'centers': model.centersLab.expand((e) => e).toList(),
    });
    await ready.future;
    return w;
  }

  /// Returns false if the frame was dropped.
  bool submit(
    FramePacket f, {
    required double threshold,
    required int minArea,
    bool freeze = false,
  }) {
    if (_busy || !_ready || _toWorker == null) return false;
    _busy = true;
    _toWorker!.send({
      'type': 'frame',
      'nv21': f.nv21,
      'w': f.width,
      'h': f.height,
      'rot': f.rotationDegrees,
      'thr': threshold,
      'minArea': minArea,
      'freeze': freeze,
    });
    return true;
  }

  /// Re-scores the top candidates of a blob from the last frozen frame with
  /// dense template matching. Result arrives on [verified].
  void verify(int blobIndex) {
    _toWorker?.send({'type': 'verify', 'blob': blobIndex});
  }

  void dispose() {
    _toWorker?.send({'type': 'stop'});
    _fromWorker.close();
    _results.close();
    _verified.close();
    _errors.close();
    _isolate?.kill(priority: Isolate.immediate);
  }

  static PresortResult _decodeResult(Map msg) {
    final raw = msg['dets'] as List;
    final dets = <Detection>[];
    const stride = 10;
    for (var i = 0; i + stride - 1 < raw.length; i += stride) {
      dets.add(Detection(
        x: (raw[i] as num).toDouble(),
        y: (raw[i + 1] as num).toDouble(),
        w: (raw[i + 2] as num).toDouble(),
        h: (raw[i + 3] as num).toDouble(),
        cluster: raw[i + 4] as int,
        row: raw[i + 5] as int,
        col: raw[i + 6] as int,
        rot: raw[i + 7] as int,
        conf: (raw[i + 8] as num).toDouble(),
        // raw[i + 9]: raw index distance, unused by the UI
      ));
    }
    return PresortResult(
      detections: dets,
      frameW: msg['fw'] as int,
      frameH: msg['fh'] as int,
      millis: msg['ms'] as int,
      frozenJpeg: msg['jpeg'] as Uint8List?,
    );
  }

  static VerifyResult _decodeVerify(Map msg) {
    final raw = msg['cands'] as List;
    final out = <VerifiedCandidate>[];
    for (var i = 0; i + 3 < raw.length; i += 4) {
      out.add(VerifiedCandidate(
        raw[i] as int,
        raw[i + 1] as int,
        raw[i + 2] as int,
        (raw[i + 3] as num).toDouble(),
      ));
    }
    return VerifyResult(msg['blob'] as int, out, msg['png'] as Uint8List?);
  }

  // ---------------------------------------------------------------- isolate

  static void _entry(SendPort toMain) {
    final port = ReceivePort();
    toMain.send(port.sendPort);
    _WorkerState? st;

    port.listen((msg) {
      final m = msg as Map;
      try {
        switch (m['type']) {
          case 'init':
            st = _WorkerState.init(m);
            toMain.send({'type': 'ready'});
          case 'frame':
            if (st != null) toMain.send(st!.processFrame(m));
          case 'verify':
            if (st != null) toMain.send(st!.verify(m['blob'] as int));
          case 'stop':
            port.close();
            Isolate.exit();
        }
      } catch (e) {
        toMain.send({'type': 'error', 'error': e.toString()});
      }
    });
  }
}

/// All native state lives here, inside the worker isolate.
class _WorkerState {
  _WorkerState._({
    required this.rows,
    required this.cols,
    required this.k,
    required this.centers,
    required this.refLabBlur,
    required this.index,
  });

  final int rows;
  final int cols;
  final int k;
  final List<List<double>> centers;

  /// Lab reference, lightly blurred, for dense verification.
  final cv.Mat refLabBlur;

  /// (rows*cols*4) x kDescLen float descriptors; row = cell*4 + rotation.
  final cv.Mat index;

  // Last frozen frame, for tap-to-verify.
  cv.Mat? frozenLab;
  List<_BlobFull> frozenBlobs = const [];

  static _WorkerState init(Map m) {
    final refPath = m['refPath'] as String;
    final rows = m['rows'] as int;
    final cols = m['cols'] as int;
    final k = m['k'] as int;
    final flat = (m['centers'] as List).cast<double>();
    final centers = List.generate(k, (i) => flat.sublist(i * 3, i * 3 + 3));

    final ref = cv.imread(refPath, flags: cv.IMREAD_COLOR);
    if (ref.isEmpty) throw Exception('Reference image missing: $refPath');
    final refLab = cv.cvtColor(ref, cv.COLOR_BGR2Lab);
    ref.dispose();
    final refLabBlur = cv.gaussianBlur(refLab, (3, 3), 0);

    // One kDescGrid x kDescGrid block per cell == mean Lab over sub-blocks.
    final grid = cv.resize(refLab, (cols * kDescGrid, rows * kDescGrid), interpolation: cv.INTER_AREA);
    refLab.dispose();
    final g = grid.data;
    final gw = cols * kDescGrid;
    final n = rows * cols;
    final desc = Float32List(n * 4 * kDescLen);
    final cell = Float32List(kDescLen);
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        var o = 0;
        for (var gy = 0; gy < kDescGrid; gy++) {
          final py = r * kDescGrid + gy;
          for (var gx = 0; gx < kDescGrid; gx++) {
            final px = c * kDescGrid + gx;
            final i = (py * gw + px) * 3;
            cell[o++] = g[i] * kLWeight;
            cell[o++] = g[i + 1].toDouble();
            cell[o++] = g[i + 2].toDouble();
          }
        }
        final base = (r * cols + c) * 4 * kDescLen;
        for (var rot = 0; rot < 4; rot++) {
          _writeRotated(cell, rot, desc, base + rot * kDescLen);
        }
      }
    }
    grid.dispose();
    final index = cv.Mat.fromList(n * 4, kDescLen, cv.MatType.CV_32FC1, desc);

    return _WorkerState._(
      rows: rows,
      cols: cols,
      k: k,
      centers: centers,
      refLabBlur: refLabBlur,
      index: index,
    );
  }

  /// Writes [src] (a g x g x 3 grid) rotated [rot]*90 deg clockwise into [dst].
  static void _writeRotated(Float32List src, int rot, Float32List dst, int off) {
    const g = kDescGrid;
    for (var y = 0; y < g; y++) {
      for (var x = 0; x < g; x++) {
        int sy, sx;
        switch (rot) {
          case 1: // 90 CW: new(y,x) = old(g-1-x, y)
            sy = g - 1 - x;
            sx = y;
          case 2: // 180
            sy = g - 1 - y;
            sx = g - 1 - x;
          case 3: // 270 CW (= 90 CCW): new(y,x) = old(x, g-1-y)
            sy = x;
            sx = g - 1 - y;
          default:
            sy = y;
            sx = x;
        }
        final si = (sy * g + sx) * 3;
        final di = off + (y * g + x) * 3;
        dst[di] = src[si];
        dst[di + 1] = src[si + 1];
        dst[di + 2] = src[si + 2];
      }
    }
  }

  int nearestCluster(double l, double a, double b) {
    var best = 0;
    var bestD = double.infinity;
    for (var i = 0; i < k; i++) {
      final c = centers[i];
      final dl = (l - c[0]) * kLWeight;
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

  /// Inner-cropped rect of a blob in full-frame coordinates.
  static cv.Rect _innerRect(_BlobFull b, int maxW, int maxH) {
    final ix = b.x + (b.w * kInset).round();
    final iy = b.y + (b.h * kInset).round();
    var iw = (b.w * (1 - 2 * kInset)).round();
    var ih = (b.h * (1 - 2 * kInset)).round();
    if (ix + iw > maxW) iw = maxW - ix;
    if (iy + ih > maxH) ih = maxH - iy;
    return cv.Rect(ix, iy, math.max(iw, 1), math.max(ih, 1));
  }

  /// kDescLen-vector for one blob from the full-res Lab frame, or null if too small.
  Float32List? _describe(cv.Mat fullLab, _BlobFull b) {
    final r = _innerRect(b, fullLab.cols, fullLab.rows);
    if (r.width < kDescGrid * 2 || r.height < kDescGrid * 2) return null;
    final roi = fullLab.region(r);
    final small = cv.resize(roi, (kDescGrid, kDescGrid), interpolation: cv.INTER_AREA);
    final d = small.data;
    final out = Float32List(kDescLen);
    for (var i = 0; i < kDescGrid * kDescGrid; i++) {
      out[i * 3] = d[i * 3] * kLWeight;
      out[i * 3 + 1] = d[i * 3 + 1].toDouble();
      out[i * 3 + 2] = d[i * 3 + 2].toDouble();
    }
    small.dispose();
    return out;
  }

  Map<String, dynamic> processFrame(Map m) {
    final sw = Stopwatch()..start();
    final w = m['w'] as int;
    final h = m['h'] as int;
    final rot = m['rot'] as int;
    final thr = m['thr'] as double;
    final minArea = m['minArea'] as int;
    final freeze = m['freeze'] as bool;
    final nv21 = m['nv21'] as Uint8List;

    final yuv = cv.Mat.fromList(h * 3 ~/ 2, w, cv.MatType.CV_8UC1, nv21);
    var full = cv.cvtColor(yuv, cv.COLOR_YUV2BGR_NV21);
    yuv.dispose();
    if (rot == 90 || rot == 180 || rot == 270) {
      final code = rot == 90
          ? cv.ROTATE_90_CLOCKWISE
          : rot == 180
              ? cv.ROTATE_180
              : cv.ROTATE_90_COUNTERCLOCKWISE;
      final r = cv.rotate(full, code);
      full.dispose();
      full = r;
    }

    final scale = kWorkWidth / full.cols;
    final small = cv.resize(full, (kWorkWidth, (full.rows * scale).round()), interpolation: cv.INTER_AREA);
    final seg = segmentPieces(small, threshold: thr, minArea: minArea);
    final fw = small.cols;
    final fh = small.rows;
    final up = full.cols / small.cols;

    final fullLab = cv.cvtColor(full, cv.COLOR_BGR2Lab);
    final blobs = <_BlobFull>[];
    final queries = <Float32List>[];
    final queryOwner = <int>[]; // blob index per query row
    for (var i = 0; i < seg.blobs.length; i++) {
      final b = seg.blobs[i];
      final bf = _BlobFull(
        x: (b.x * up).round(),
        y: (b.y * up).round(),
        w: (b.w * up).round(),
        h: (b.h * up).round(),
        nx: b.x / fw,
        ny: b.y / fh,
        nw: b.w / fw,
        nh: b.h / fh,
        cluster: nearestCluster(b.l, b.a, b.b),
      );
      blobs.add(bf);
      final d = _describe(fullLab, bf);
      if (d != null) {
        queries.add(d);
        queryOwner.add(i);
      }
    }

    // One native brute-force kNN for every piece in the frame.
    if (queries.isNotEmpty) {
      final flat = Float32List(queries.length * kDescLen);
      for (var i = 0; i < queries.length; i++) {
        flat.setRange(i * kDescLen, (i + 1) * kDescLen, queries[i]);
      }
      final q = cv.Mat.fromList(queries.length, kDescLen, cv.MatType.CV_32FC1, flat);
      final (dist, nidx) = cv.batchDistance(q, index, cv.MatType.CV_32F, normType: cv.NORM_L2, K: kKnn);
      for (var i = 0; i < queries.length; i++) {
        final b = blobs[queryOwner[i]];
        final cands = <int>[];
        final dists = <double>[];
        for (var j = 0; j < kKnn; j++) {
          final idx = nidx.at<int>(i, j);
          cands.add(idx);
          dists.add(idx < 0 ? double.infinity : dist.at<double>(i, j));
        }
        b.candidates = cands;
        final best = cands[0];
        if (best < 0) continue;
        final bestCell = best ~/ 4;
        b.row = bestCell ~/ cols;
        b.col = bestCell % cols;
        b.rot = (best % 4) * 90;
        b.dist = dists[0];
        // Ratio test against the nearest candidate that is not a neighbour cell.
        var d2 = double.infinity;
        for (var j = 1; j < kKnn; j++) {
          if (cands[j] < 0) break;
          final cell = cands[j] ~/ 4;
          final rr = cell ~/ cols;
          final cc = cell % cols;
          if ((rr - b.row).abs() > 1 || (cc - b.col).abs() > 1) {
            d2 = dists[j];
            break;
          }
        }
        b.conf = d2.isFinite && d2 > 0 ? (1 - dists[0] / d2).clamp(0.0, 1.0).toDouble() : 0.5;
      }
      q.dispose();
      dist.dispose();
      nidx.dispose();
    }

    final out = <num>[];
    for (final b in blobs) {
      out.addAll([b.nx, b.ny, b.nw, b.nh, b.cluster, b.row, b.col, b.rot, b.conf, b.dist]);
    }

    Uint8List? jpeg;
    if (freeze) {
      final (_, bytes) = cv.imencode('.jpg', full, params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 88]));
      jpeg = bytes;
      frozenLab?.dispose();
      frozenLab = fullLab;
      frozenBlobs = blobs;
    } else {
      fullLab.dispose();
    }

    seg.dispose();
    small.dispose();
    full.dispose();

    return {
      'type': 'result',
      'dets': out,
      'fw': fw,
      'fh': fh,
      'ms': sw.elapsedMilliseconds,
      'jpeg': jpeg,
    };
  }

  /// Dense re-scoring of one frozen blob's index candidates.
  Map<String, dynamic> verify(int blobIndex) {
    final lab = frozenLab;
    if (lab == null || blobIndex < 0 || blobIndex >= frozenBlobs.length) {
      return {'type': 'verified', 'blob': blobIndex, 'cands': const <num>[], 'png': null};
    }
    final b = frozenBlobs[blobIndex];
    final r = _innerRect(b, lab.cols, lab.rows);
    final roi = lab.region(r);
    final patch = cv.resize(roi, (kCellPx, kCellPx), interpolation: cv.INTER_AREA);
    final patchBlur = cv.gaussianBlur(patch, (3, 3), 0);
    final variants = [
      patchBlur,
      cv.rotate(patchBlur, cv.ROTATE_90_CLOCKWISE),
      cv.rotate(patchBlur, cv.ROTATE_180),
      cv.rotate(patchBlur, cv.ROTATE_90_COUNTERCLOCKWISE),
    ];

    // Distinct candidate cells (the index returns cell*4+rot entries).
    final cells = <int>{};
    for (final e in b.candidates) {
      if (e >= 0) cells.add(e ~/ 4);
    }
    if (cells.isEmpty && b.row >= 0) cells.add(b.row * cols + b.col);

    final scored = <List<num>>[];
    const pad = 2; // cells of context around the candidate
    final refW = cols * kCellPx;
    final refH = rows * kCellPx;
    for (final cell in cells) {
      final cr = cell ~/ cols;
      final cc = cell % cols;
      final x0 = math.max(0, (cc - pad) * kCellPx);
      final y0 = math.max(0, (cr - pad) * kCellPx);
      final x1 = math.min(refW, (cc + pad + 1) * kCellPx);
      final y1 = math.min(refH, (cr + pad + 1) * kCellPx);
      final win = refLabBlur.region(cv.Rect(x0, y0, x1 - x0, y1 - y0));
      var bestScore = -1.0;
      var bestRot = 0;
      var bestRow = cr;
      var bestCol = cc;
      for (var v = 0; v < 4; v++) {
        final res = cv.matchTemplate(win, variants[v], cv.TM_CCOEFF_NORMED);
        final (_, mx, _, loc) = cv.minMaxLoc(res);
        if (mx > bestScore) {
          bestScore = mx;
          bestRot = v * 90;
          bestRow = ((y0 + loc.y + kCellPx / 2) / kCellPx).floor().clamp(0, rows - 1).toInt();
          bestCol = ((x0 + loc.x + kCellPx / 2) / kCellPx).floor().clamp(0, cols - 1).toInt();
        }
        res.dispose();
      }
      scored.add([bestRow, bestCol, bestRot, bestScore]);
    }
    scored.sort((a, b) => (b[3] as double).compareTo(a[3] as double));

    // Piece thumbnail (frozen Lab frame back to BGR for display).
    final thumbLab = cv.resize(lab.region(cv.Rect(b.x, b.y, b.w, b.h)), (96, 96), interpolation: cv.INTER_AREA);
    final thumbBgr = cv.cvtColor(thumbLab, cv.COLOR_Lab2BGR);
    final (_, png) = cv.imencode('.png', thumbBgr);
    thumbLab.dispose();
    thumbBgr.dispose();

    for (final v in variants) {
      v.dispose();
    }
    patch.dispose();

    return {
      'type': 'verified',
      'blob': blobIndex,
      'cands': scored.expand((e) => e).toList(),
      'png': png,
    };
  }
}

class _BlobFull {
  _BlobFull({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.nx,
    required this.ny,
    required this.nw,
    required this.nh,
    required this.cluster,
  });

  final int x, y, w, h; // full-frame pixels
  final double nx, ny, nw, nh; // normalised
  final int cluster;
  int row = -1;
  int col = -1;
  int rot = 0;
  double conf = 0;
  double dist = 0;
  List<int> candidates = const [];
}
