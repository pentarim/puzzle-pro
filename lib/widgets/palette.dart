import 'package:flutter/material.dart';

/// Distinct overlay colours for up to 24 clusters (wraps after that).
const List<Color> kClusterPalette = [
  Color(0xFFE6194B),
  Color(0xFF3CB44B),
  Color(0xFFFFE119),
  Color(0xFF4363D8),
  Color(0xFFF58231),
  Color(0xFF911EB4),
  Color(0xFF42D4F4),
  Color(0xFFF032E6),
  Color(0xFFBFEF45),
  Color(0xFFFABED4),
  Color(0xFF469990),
  Color(0xFFDCBEFF),
  Color(0xFF9A6324),
  Color(0xFFFFFAC8),
  Color(0xFF800000),
  Color(0xFFAAFFC3),
  Color(0xFF808000),
  Color(0xFFFFD8B1),
  Color(0xFF000075),
  Color(0xFFA9A9A9),
  Color(0xFFFFFFFF),
  Color(0xFF000000),
  Color(0xFFFF7F50),
  Color(0xFF7FFF00),
];

Color clusterColor(int i) => kClusterPalette[i % kClusterPalette.length];
