/// Static barcode (EAN/UPC) -> puzzle grid table owned by the app.
///
/// Empty on purpose: fill in as puzzles are verified. Entries the user types in
/// after a lookup miss are persisted separately in [AppState.learnedGrid].
typedef Grid = ({int rows, int cols});

const Map<String, Grid> kGridByBarcode = <String, Grid>{
  // '4005556178032': (rows: 75, cols: 120), // example shape, unverified
};

Grid? lookupGrid(String barcode, Map<String, String> learned) {
  final hit = kGridByBarcode[barcode];
  if (hit != null) return hit;
  final l = learned[barcode];
  if (l == null) return null;
  final parts = l.split(',');
  if (parts.length != 2) return null;
  final r = int.tryParse(parts[0]);
  final c = int.tryParse(parts[1]);
  if (r == null || c == null) return null;
  return (rows: r, cols: c);
}
