import 'package:opencv_dart/opencv_dart.dart' as cv;

/// One detected piece in image coordinates.
class Blob {
  Blob({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.area,
    required this.l,
    required this.a,
    required this.b,
  });

  final int x, y, w, h;
  final double area;

  /// Mean Lab (OpenCV 8-bit scale) of the piece pixels.
  final double l, a, b;
}

class Segmentation {
  Segmentation(this.blobs, this.mask, this.lab, this.bgLab);

  final List<Blob> blobs;

  /// 8UC1 foreground mask (same size as the input).
  final cv.Mat mask;

  /// Lab conversion of the input.
  final cv.Mat lab;

  /// Estimated background Lab.
  final List<double> bgLab;

  void dispose() {
    mask.dispose();
    lab.dispose();
  }
}

/// Estimates the table colour from the frame border (median per channel).
List<double> estimateBackgroundLab(cv.Mat lab) {
  final rows = lab.rows;
  final cols = lab.cols;
  final data = lab.data;
  final band = (rows < cols ? rows : cols) ~/ 20 + 1;
  final ls = <int>[], as_ = <int>[], bs = <int>[];
  void take(int r, int c) {
    final i = (r * cols + c) * 3;
    ls.add(data[i]);
    as_.add(data[i + 1]);
    bs.add(data[i + 2]);
  }

  final step = 3;
  for (var r = 0; r < rows; r += step) {
    for (var c = 0; c < band; c += step) {
      take(r, c);
      take(r, cols - 1 - c);
    }
  }
  for (var c = 0; c < cols; c += step) {
    for (var r = 0; r < band; r += step) {
      take(r, c);
      take(rows - 1 - r, c);
    }
  }
  int median(List<int> v) {
    v.sort();
    return v[v.length ~/ 2];
  }

  return [median(ls).toDouble(), median(as_).toDouble(), median(bs).toDouble()];
}

/// Segments pieces in a BGR image lying on a plain background.
///
/// [threshold] is the weighted Lab distance from the background above which a
/// pixel is foreground. [minArea]/[maxArea] are in pixels of the input image.
Segmentation segmentPieces(
  cv.Mat bgr, {
  double threshold = 28,
  int minArea = 80,
  int? maxArea,
  List<double>? bgLab,
}) {
  final lab = cv.cvtColor(bgr, cv.COLOR_BGR2Lab);
  final bg = bgLab ?? estimateBackgroundLab(lab);

  final bgMat = cv.Mat.fromScalar(lab.rows, lab.cols, lab.type, cv.Scalar(bg[0], bg[1], bg[2]));
  final diff = cv.absDiff(lab, bgMat);
  final ch = cv.split(diff);
  // Chroma differences count double; lightness alone (shadows) is weak.
  final da = cv.convertScaleAbs(ch[1], alpha: 2);
  final db = cv.convertScaleAbs(ch[2], alpha: 2);
  final dist = cv.max(ch[0], cv.max(da, db));

  final (_, rawMask) = cv.threshold(dist, threshold, 255, cv.THRESH_BINARY);
  final kernel = cv.getStructuringElement(cv.MORPH_ELLIPSE, (5, 5));
  final opened = cv.morphologyEx(rawMask, cv.MORPH_OPEN, kernel);
  final mask = cv.morphologyEx(opened, cv.MORPH_CLOSE, kernel, iterations: 2);

  final (contours, _) = cv.findContours(mask, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);
  final maxA = maxArea ?? (lab.rows * lab.cols ~/ 4);
  final blobs = <Blob>[];
  for (final contour in contours) {
    final area = cv.contourArea(contour);
    if (area < minArea || area > maxA) continue;
    final rect = cv.boundingRect(contour);
    final roiLab = lab.region(rect);
    final roiMask = mask.region(rect);
    final m = cv.mean(roiLab, mask: roiMask);
    blobs.add(Blob(
      x: rect.x,
      y: rect.y,
      w: rect.width,
      h: rect.height,
      area: area,
      l: m.val1,
      a: m.val2,
      b: m.val3,
    ));
  }

  bgMat.dispose();
  diff.dispose();
  da.dispose();
  db.dispose();
  dist.dispose();
  rawMask.dispose();
  kernel.dispose();
  opened.dispose();

  return Segmentation(blobs, mask, lab, bg);
}
