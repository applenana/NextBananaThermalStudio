# ESPCN 2× photo display experiment

- Upstream: https://github.com/fannymonori/TF-ESPCN
- Reviewed commit: `5c628eca82028161a53e1265cc3a5b571ab8625f`
- Weights: `export/ESPCN_x2.pb`, SHA-256 `59f77351e1d7c0057bf6fe088b4a8a07e42c468c8c8aebb674a6b4ea1823221d`
- License: Apache-2.0, reproduced in LICENSE and the app's license assets.
- Original graph: 5×5 convolution 1→64 + ReLU; 3×3 64→32 + ReLU;
  3×3 32→4; NHWC DepthToSpace(2); tanh. SAME zero padding.
- `tools/import_espcn_model.py` verifies the exact graph hash and converts float32
  tensors to C++ constants, without TensorFlow or runtime model downloading.
- `espcn.cpp` is a CPU implementation of that graph. No third-party inference
  runtime is required. It accepts normalized display intensity, not degrees C.

This is an experiment using a luminance model trained on ordinary images, not a
thermal-specific reconstruction model. It may alter edges, contrast or introduce
artifacts, especially at borders. It does not recover measured thermal detail.

Only the two galleries' still-photo preview and PNG export use it, with an opt-in
switch. The regular render's temperature fields, extrema, range and color legend
remain authoritative. The live stream, alarms, temperature exports and source
capture packages are not modified. Processing runs in an isolate; slider updates
are debounced and obsolete results discarded. Failed preview falls back with an
error indication; requested AI export fails explicitly rather than silently
exporting a regular image. AI exports use an `_ai2x` filename suffix.

## Validation

- Independently compared native convolutions with OpenCV 4.12 DNN loading the
  original GraphDef (trimmed after `add_2` because its TensorFlow DepthToSpace
  importer rejects `block_size`). NumPy performs NHWC pixel shuffle and tanh.
- 5×3, 32×24 and 120×90 randomized inputs: maximum normalized difference below
  `7e-7`; 120×90 native inference approximately 45 ms on the development machine.
  These timings exclude Flutter preview and are not a real-time performance promise.
- `test/fixtures/espcn_x2_reference.json` preserves a small independent reference.
  Set `THERMAL_SR_LIBRARY` when running `test/ai_super_resolution_test.dart` to
  exercise the actual native library, in addition to state/data regression tests.
- `tools/check_ai_photo.dart` checks a full thermal-photo pipeline and writes a
  comparison under the ignored build directory. It does not operate the UI.
- Windows native build tested. Android uses the same CMake target but has not
  been built or tested on hardware in this change.
