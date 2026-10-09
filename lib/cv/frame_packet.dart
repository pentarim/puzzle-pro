import 'dart:typed_data';

import 'package:camera/camera.dart';

/// A camera frame as packed NV21 bytes, ready to ship to the worker isolate.
class FramePacket {
  FramePacket(this.nv21, this.width, this.height, this.rotationDegrees);

  final Uint8List nv21;
  final int width;
  final int height;

  /// Clockwise rotation needed to bring the frame to display orientation.
  final int rotationDegrees;
}

/// Packs a [CameraImage] into NV21. Returns null for unsupported layouts.
FramePacket? packFrame(CameraImage img, int rotationDegrees) {
  final w = img.width;
  final h = img.height;
  final expected = w * h * 3 ~/ 2;

  if (img.planes.length == 1) {
    // ImageFormatGroup.nv21: already interleaved.
    final p = img.planes[0];
    if (p.bytes.length == expected) {
      return FramePacket(p.bytes, w, h, rotationDegrees);
    }
    if (p.bytesPerRow > w) {
      // Row padding: repack.
      final out = Uint8List(expected);
      var o = 0;
      final rowsTotal = h * 3 ~/ 2;
      for (var r = 0; r < rowsTotal; r++) {
        final start = r * p.bytesPerRow;
        out.setRange(o, o + w, p.bytes, start);
        o += w;
      }
      return FramePacket(out, w, h, rotationDegrees);
    }
    return null;
  }

  if (img.planes.length == 3) {
    // ImageFormatGroup.yuv420 (YUV_420_888): Y + U + V with strides.
    final y = img.planes[0];
    final u = img.planes[1];
    final v = img.planes[2];
    final out = Uint8List(expected);
    var o = 0;

    final yb = y.bytes;
    final ys = y.bytesPerRow;
    for (var r = 0; r < h; r++) {
      out.setRange(o, o + w, yb, r * ys);
      o += w;
    }

    final uvw = w ~/ 2;
    final uvh = h ~/ 2;
    final ub = u.bytes;
    final vb = v.bytes;
    final us = u.bytesPerRow;
    final vs = v.bytesPerRow;
    final up = u.bytesPerPixel ?? 1;
    final vp = v.bytesPerPixel ?? 1;
    for (var r = 0; r < uvh; r++) {
      final uRow = r * us;
      final vRow = r * vs;
      for (var c = 0; c < uvw; c++) {
        final vi = vRow + c * vp;
        final ui = uRow + c * up;
        out[o++] = vi < vb.length ? vb[vi] : 128;
        out[o++] = ui < ub.length ? ub[ui] : 128;
      }
    }
    return FramePacket(out, w, h, rotationDegrees);
  }

  return null;
}
