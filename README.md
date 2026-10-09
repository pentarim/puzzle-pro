# Puzzle Solver (Flutter / Android)

One live mode against a rectified photo of the box art. Every loose piece in the camera frame gets, every frame:

- a coloured box = colour group (legend shows where that group lives on the box art), and
- a `R<row> C<col>` label (1‑based from the top‑left of the box art), the rotation to apply (`↺90` = turn the piece 90° counter‑clockwise), and a confidence %.

**Freeze** stops the frame as a zoomable still so labels can be read at leisure; **tap a piece** in the frozen frame to re‑score its top candidates with dense template matching and see them ringed on the box art. No per‑piece photos: ~100 pieces per frame, one native kNN call per frame.

Grid comes from a barcode → (rows, cols) lookup table the app owns (`lib/data/grid_lookup.dart`, empty). On a miss you type rows × cols once; the pair is remembered against that barcode.

> Untested build. Written against opencv_dart 2.x (dartcv4) source signatures, camera 0.11, mobile_scanner 6+. Expect a first round of compile fixes.

## Build

Requirements: Flutter **≥ 3.38.1** (Dart ≥ 3.10, needed by opencv_dart 2.x native‑assets hooks), Android SDK + NDK, **CMake on PATH** (opencv_dart builds its native lib during `flutter build`; first build fetches the OpenCV SDK, ~100 MB — set `DARTCV_CACHE_DIR=$HOME/.cache/dartcv` to keep it).

```bash
flutter create --platforms=android --org com.upandrunning puzzle_solver_app
cd puzzle_solver_app
# drop in this repo's files
cp -r ../puzzle_solver/lib ../puzzle_solver/pubspec.yaml .
flutter pub get
flutter pub upgrade --major-versions     # bump deps to current majors
```

### Android config

`android/app/build.gradle.kts`:

```kotlin
android {
    compileSdk = 35
    defaultConfig {
        minSdk = 24            // opencv_dart + camerax
        // ...
    }
}
```

`android/app/src/main/AndroidManifest.xml`, inside `<manifest>` above `<application>`:

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-feature android:name="android.hardware.camera" android:required="false" />
```

Then:

```bash
flutter run --release        # debug is fine too; CV is native either way
```

If the build complains about hooks / native assets on an older toolchain: `flutter config --enable-native-assets`, or pin `opencv_dart: ^1.4.5` (last 1.x; same Dart API used here, prebuilt binaries, works on Flutter < 3.38).

## Flow on the phone

1. **Grid** → scan barcode (lookup is empty, so you'll get a miss) → enter rows × cols → Save.
2. **Reference image** → Photograph box → tap the four corners of the *art area* (TL, TR, BR, BL) → Rectify. The app builds the colour model (k = 10 groups, slider to change).
3. **Solve** → point the phone at the pile on a plain table (first open builds the cell index, ~1 s). Labels menu switches between row/col, colour group, or both. Tap a swatch to isolate one colour group; map icon shows where that group is on the box. If boxes are drawn rotated relative to the pieces, hit the rotate icon in the app bar.
4. **Freeze** → zoom/pan the still, read labels. **Tap a piece** → sheet with its dense-verified candidates (best first) ringed on the box art. **Resume live** to go back.

Sliders: **BG** is the Lab distance from the table colour that counts as "piece" — raise it if the table shows up as blobs, lower it if pale pieces vanish. **Conf** hides labels below that confidence (a `?` is drawn instead), so you can work only the sure ones first.

## How it works

| Stage | Where | Method |
|---|---|---|
| Rectify | `screens/rectify_screen.dart` | 4‑point `getPerspectiveTransform` → `warpPerspective` to `cols·16 × rows·16` px (16 px per cell, `kCellPx`) |
| Colour model | `cv/reference_model.dart` | Lab → `INTER_AREA` resize to `cols × rows` (= mean Lab per cell) → `kmeans(k)` |
| Segmentation | `cv/segmentation.dart` | Background = median Lab of the frame border; per‑pixel weighted Lab distance (a/b ×2) → threshold → open/close → external contours |
| Cell index | `cv/presort_worker.dart` (`_WorkerState.init`) | Reference Lab → `INTER_AREA` resize to `cols·4 × rows·4` → one 4×4×3 = 48‑float descriptor per cell × 4 rotations (L weighted 0.6) → `(rows·cols·4) × 48` float Mat, built once in the worker isolate |
| Live labels | `cv/presort_worker.dart` (`processFrame`) | NV21 → BGR → rotate → 320 px wide → segment → cluster per blob; inner 60 % crop of each blob → 4×4 Lab descriptor → **one `batchDistance` kNN (K=6) for all pieces** → best entry gives row, col, rotation; confidence = ratio test against the nearest non‑neighbour cell. Persistent isolate; frames drop while busy |
| Freeze | same, `freeze=true` | frame also returned as JPEG; full‑res Lab frame and blob rects kept in the worker |
| Tap‑to‑verify | `_WorkerState.verify` | blob → 16×16 Lab patch → `matchTemplate` `TM_CCOEFF_NORMED` × 4 rotations inside a 5×5‑cell window around each index candidate → re‑ranked list |

## Known limits (v1)

- Colour/layout only. Uniform regions (sky, sea) give low confidence and near‑arbitrary labels there — the Conf slider hides those; place the confident ones, then the rest by shape. Edge/tab shape matching is the obvious v2.
- Corner tap precision on a 120‑col puzzle is ~1 cell. Fill the screen with the box when shooting it.
- Plain table, pieces not touching; touching pieces merge into one blob and get one (wrong) label.
- Hand‑held: expect labels to flicker between neighbouring cells on borderline pieces. Freeze and tap for the dense answer.
- Already‑placed cells are still in the index (marking solved regions was deferred).

## Tuning knobs

| Knob | File | Default |
|---|---|---|
| `kCellPx` px per cell in reference | `cv/reference_model.dart` | 16 |
| `kWorkWidth` live processing width | `cv/presort_worker.dart` | 320 |
| Lightness weight (clusters + descriptors) | `reference_model.dart` (`* 0.6`) / `presort_worker.dart` (`kLWeight`) | 0.6 |
| Descriptor inset / grid / kNN | `cv/presort_worker.dart` (`kInset`, `kDescGrid`, `kKnn`) | 0.2 / 4 / 6 |
| Live `minArea` | `screens/presort_screen.dart` | 60 px |
