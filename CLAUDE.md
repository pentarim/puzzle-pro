# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Flutter/Android jigsaw-puzzle helper. The user photographs the box art, then points the phone at loose pieces and gets a live overlay giving each piece a colour group, a `R<row> C<col>` cell, a rotation and a confidence. Computer vision runs through `opencv_dart` (dartcv4) in a background isolate. README.md has the on-phone flow, the stage-by-stage method table, known limits and the tuning-knob table; read it before changing CV behaviour.

## Repository shape

This directory holds **only `lib/`, `pubspec.yaml` and two markdown files**: no `android/`, `test/`, `analysis_options.yaml`, `pubspec.lock` or `.git`. It is a drop-in for a scaffolded Flutter app (`puzzle_solver_app`, see below). No such scaffold exists on this machine, so nothing builds or runs in place. Edits made here must be copied into the scaffold (or made there and copied back); keep the two in sync.

Toolchain on this machine (checked 2026-10-09): Flutter 3.47.7 / Dart 3.13.5 via snap, CMake 3.22.1 and `adb`, all on PATH. That satisfies the pubspec minimums (Flutter ≥ 3.38.1 / Dart ≥ 3.10, required by opencv_dart 2.x native-assets hooks).

## Commands

### Static analysis (works without the scaffold)

`flutter pub get` **fails on the checked-in pubspec**: `opencv_dart: ^2.3.0` matches nothing on pub.dev (latest 2.x is 2.2.2, which pulls dartcv4 2.3.1). Lower it to `^2.2.2` first. Then, either here (creates `.dart_tool/` and `pubspec.lock`) or on a copy of `lib/` + `pubspec.yaml` in a scratch dir:

```bash
flutter pub get
printf 'include: package:flutter_lints/flutter.yaml\n' > analysis_options.yaml  # what `flutter create` generates; without it only core lints run
flutter analyze
```

Result on 2026-10-09 against the versions pub resolves (opencv_dart 2.2.2, camera 0.11.4, mobile_scanner 6.0.11, flutter_lints 5.0.0): **No issues found**. After `flutter pub upgrade --major-versions` (camera 0.12.1, mobile_scanner 7.4.2, flutter_lints 6.0.0): no errors, two `unnecessary_underscores` infos from `(_, __)` separator builders. The "never compiled, expect a round of compile fixes" warning in README is therefore stale at the analyser level; runtime behaviour and the native OpenCV build are still unverified.

There are no tests; `flutter analyze` is the only check. When a `cv.*` call does fail to resolve after a dependency bump, check the dartcv4 source for the current signature rather than rewriting the algorithm. dartcv4 conventions used throughout: sizes are `(width, height)` records, multi-value results are records destructured as `final (_, labels, centers) = cv.kmeans(...)`, `Mat.at<T>(r, c)` is typed, and `region()` returns a view.

### Full build (needs the Android scaffold)

From README:

```bash
flutter create --platforms=android --org com.upandrunning puzzle_solver_app
cd puzzle_solver_app
cp -r ../puzzle_solver/lib ../puzzle_solver/pubspec.yaml .
flutter pub get
flutter pub upgrade --major-versions   # optional; see analyser results above
flutter analyze
flutter run --release                  # debug is fine too; CV is native either way
```

Then apply the Android config from README: `minSdk = 24`, `compileSdk = 35`, and the CAMERA permission/feature in the manifest. The first build downloads the OpenCV SDK (~100 MB); set `DARTCV_CACHE_DIR=$HOME/.cache/dartcv` to keep it. Fallbacks if native-assets hooks misbehave: `flutter config --enable-native-assets`, or pin `opencv_dart: ^1.4.5` (prebuilt binaries, same Dart API).

## Architecture

### Three gated steps, one persisted state object

`main.dart` loads `AppState` (`lib/state/app_state.dart`) and wraps the app in `AppStateScope`, an `InheritedNotifier`. Use `AppStateScope.of(context)` inside `build` to subscribe and `AppStateScope.read(context)` in `initState`/callbacks. `HomeScreen` gates the flow on `hasGrid` → `hasReference && hasModel` → `readyToSolve`.

`AppState.save()` writes SharedPreferences and is the **only** place `notifyListeners()` is called, so the pattern is: mutate fields, then `save()`. Gotcha: `save()` only writes fields that are non-null, so setting a field to null never removes its prefs key. `setGrid()` nulls the reference and model in memory (the grid dimensions define every image size below), but that invalidation does not survive a restart; `load()` brings the old paths and model back.

Large artefacts are files, always at the same path:
- `<documents>/reference_rectified.png`, written by `RectifyScreen`.
- `<documents>/reference_model.json`, written by `ReferenceScreen._buildModel` via `ReferenceModel.saveToFile`.
- `<temp>/box_work.jpg`, the ≤ 2400 px working copy of the box photo that `RectifyScreen` displays and warps from. Corner taps are stored in this image's pixel coordinates, so rectification resolution is capped by it, not by the original photo.

Because the paths never change and Flutter caches `FileImage` by path, both writers call `FileImage(File(path)).evict()` right after writing. New code that rewrites one of these files must do the same or the UI keeps showing the previous image.

### The 16 px-per-cell invariant

`kCellPx` in `lib/cv/reference_model.dart` is 16. The rectified reference is exactly `cols·16 × rows·16` px, so pixel ↔ cell mapping is integer arithmetic everywhere:
- `ReferenceModel.build`: `INTER_AREA` resize to `(cols, rows)` yields the mean Lab per cell; k-means on those gives the clusters. `cellLabels`/`cellLab` are row-major, index `r * cols + c`.
- Worker index: resize to `(cols·4, rows·4)` yields one 4×4×3 = 48-float descriptor per cell (`kDescGrid`, `kDescLen`).
- Verify: template windows are `(2·pad+1)·kCellPx` crops of the blurred Lab reference, and match locations are converted back to cells by dividing by `kCellPx`.

Changing `kCellPx` or the grid invalidates the reference image and model; both must be rebuilt.

### Colour conventions

Everything is compared in OpenCV 8-bit Lab (L 0..255, a/b 0..255 with 128 neutral). Lightness is distrusted under table lighting: L is weighted 0.6 in `ReferenceModel.nearest` (a literal `* 0.6`) and in the worker's `nearestCluster` (`kLWeight`). Those two must stay in sync; today only the worker copy is actually called. Segmentation (`lib/cv/segmentation.dart`) instead doubles the a/b differences and takes the per-pixel channel max against the median border colour, so a shadow alone is not foreground.

Cluster indices are raw k-means output (`KMEANS_PP_CENTERS`, 3 attempts); nothing sorts them, so group numbers and palette colours reshuffle on every rebuild and must not be persisted or compared across builds. `ReferenceModel.k` is `min(requested k, cells)`; `AppState.k` is the requested value from the slider (4..24). The UI sizes legends from `model.k`.

### Worker isolate protocol (`lib/cv/presort_worker.dart`)

`PresortWorker` (main isolate) and `_WorkerState` (worker isolate) exchange plain `Map`s keyed by `'type'`: `init` / `frame` / `verify` / `stop` inbound; `ready` / `result` / `verified` / `error` outbound. All native state for live solving (reference Lab, descriptor index, the last frozen frame and its blobs) lives only in the worker. `init` carries rows, cols, k, the flattened cluster centres and `refPath`; the worker re-reads the PNG itself and never sees `cellLabels`/`cellLab`. Any exception in the worker becomes an `error` message; during `init` that makes `spawn()` throw.

- Detections cross the port as a flat `num` list with **stride 10**: `nx, ny, nw, nh, cluster, row, col, rot, conf, dist`. `processFrame`'s `out.addAll` and `_decodeResult` must change together. Verify candidates use stride 4.
- Frame-drop policy: `submit()` returns false while `_busy`, so the UI never queues frames.
- Index row = `cell * 4 + rot`, with cell = `row * cols + col`. Rotation `r` in the index is the reference cell rotated `r·90°` clockwise (`_writeRotated`), so the reported `rot` is the counter-clockwise turn to apply to the piece (shown as `↺`).
- Confidence is a ratio test, `1 − d0/d2`, where `d2` is the nearest kNN hit that is not within one cell of the best (adjacent cells are near-duplicates and must not count). With no such hit among the `kKnn` = 6 neighbours the confidence is 0.5.
- Freeze: a frame submitted with `freeze=true` also comes back as JPEG, and the worker keeps `frozenLab` + `frozenBlobs`. The tap-to-verify `blobIndex` indexes `PresortResult.detections`, which is the same order as `frozenBlobs`. Do not filter or reorder detections between the worker and the UI.

### Coordinate spaces inside one frame

Camera `CameraImage` → NV21 (`lib/cv/frame_packet.dart` packs both the 1-plane `nv21` and 3-plane `yuv420` layouts) → BGR → rotated by sensor orientation (or the user's app-bar override) into display orientation → `small` at `kWorkWidth` = 320 px for segmentation → blob rects scaled back by `up` to the full-res frame for descriptors → emitted **normalised 0..1** relative to the display-oriented frame. `frameW`/`frameH` in the result are the dimensions of `small`, while the frozen JPEG is full-res; only the aspect ratio is used. `_OverlayPainter` and `_FrozenView` in `presort_screen.dart` multiply by widget size; `AspectRatio(frameW / frameH)` keeps the overlay aligned with the image.

### Native memory

`cv.Mat` objects are released explicitly. The existing code disposes every Mat it creates before returning (`processFrame`, `verify`, `segmentPieces`, `ReferenceModel.build`) and does not dispose `region()` views. Follow the same pattern in new CV code; a Mat that is handed to another object (`Segmentation.mask`/`.lab`, `frozenLab`) is disposed by its new owner.

### Screens and widgets

`lib/screens/` holds the three steps plus `BarcodeScreen` (pops with the first code seen) and `RectifyScreen` (four taps TL, TR, BR, BL → `getPerspectiveTransform2f` → `warpPerspective` → pops with the PNG path). `PresortScreen` owns the camera (`ResolutionPreset.medium`, `ImageFormatGroup.nv21`) and the worker; it stops the camera on pause and restarts it on resume but keeps the worker and any frozen frame. Live `minArea` is hard-coded to 60 there. `lib/widgets/` are shared painters: `ClusterMap` (reference tinted by cluster, swatch row), `CandidateMap` (verify rings on the box art) and `palette.dart` (24 overlay colours, wraps).

`lib/data/grid_lookup.dart` is an intentionally empty static barcode → (rows, cols) table. Pairs the user types after a lookup miss are persisted in `AppState.learnedGrid`, not here.
