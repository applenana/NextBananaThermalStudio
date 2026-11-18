# Thermal-PFT display super-resolution

The optional **Windows CUDA/CPU** bundle lives beside the application in
`photo_ai/`. Only Thermal-PFT L1 and TV checkpoints remain. Both infer at native
3×. There is no automatic network download or Android inference runtime.

## Provenance and validation

| Model | Architecture / pinned source | Checkpoint revision |
| --- | --- | --- |
| PFT L1 | `guillepinto/THERMAL-PFT-SR`, `644aed807dc9c4c56ad9e9aaa2711a9ccb9106d4`, `basicsr/archs/pft_arch.py` | `SemilleroCV/thermal-pft-light-srx3`, `5002f089dcbd43c6835620136e0c0318707276cf` |
| PFT TV | Same architecture | `SemilleroCV/thermal-pft-light-srx3-cross-channel-tv`, `98dfd184de8d364d19982190d70c2c692333aaf5` |

Exact URLs are in `prepare_runtime.py`, SHA-256 hashes in `weights-manifest.json`.
Each model load verifies the hash and strictly loads its state dictionary with
`torch.load(weights_only=True)`. Architecture and checkpoint licenses are
Apache-2.0; `PFT-LICENSE.txt` and the app license registry retain attribution.
Python and dependency distributions retain their own licenses.

PFT's custom CUDA sparse kernels are replaced by batched products and indexed
selection, tested against explicit selected-element products. No CUDA toolkit
or custom extension build is required. Training-only framework imports are
replaced by `vendor/compat.py`.

Input is the ordinary pipeline's normalized **pre-palette** intensity. Three
identical channels feed PFT; output luminance uses 0.299/0.587/0.114 weights.
Symmetric padding reaches a 32-pixel window multiple (replicate padding for
smaller inputs), then the output is cropped to exactly 3×. Each output axis is
limited to 1024. Palette, mapping curve and fusion use the existing pipeline.
AI never supplies measured temperatures or modifies the source data.

## Photo and live display

Both galleries retain the L1/TV model dropdown, with Off or native 3×. Default
model is TV; AI starts disabled. Missing model bundles disable their controls.
Photo previews debounce parameter changes and discard obsolete results. Exports
capture the selected model and fail explicitly if inference fails.

Windows live display adds **AI 实时超分 · PFT TV 3×**, initially off. It starts
inference immediately, runs only one job, and overwrites a single pending slot
with the newest sensor frame. New arrivals do not discard a finished valid job.
The shared worker serializes live and photo requests. Source preprocessing and
coloring execute in Dart isolates; CUDA is used when available, with CPU fallback.
The header shows actual block progress, backend and the previous job duration.

Live display uses the latest completed AI RGB while measured temperatures,
markers and legend continue updating from the current sensor frame. AI image
updates therefore lag the measurements by the inference/queue time; this is not
an increase in sensor rate or true measurement resolution. RGB is resized to the
existing canvas grid so measurement/recording coordinates do not move when AI is
toggled. There is no AI change to captured raw photo/video data. Normal and
fullscreen views share this state. Disabling, stopping/disconnecting, or changing
render parameters discards old results. Errors restore ordinary display; toggle
AI off/on to retry. While loading, ordinary live rendering remains visible.

## Runtime and packaging

The worker reads sequential JSON lines, with base64 little-endian float32 arrays.
Progress events precede the final response; stderr is diagnostic only. One model
is resident at a time. Requests time out after five minutes; failed processes are
restarted, and the worker exits after five idle minutes or parent EOF.
CUDA allocation/driver/kernel failures retry once on CPU and retain the fallback
reason. Other errors propagate. FP32 is retained with TF32 disabled.

Prepare using Windows Python 3.13:

```powershell
python tools/photo_ai/prepare_runtime.py --backend cuda --output build/photo-ai-cuda-runtime
cmake -S windows -B build/windows/x64 -DPHOTO_AI_RUNTIME="$PWD/build/photo-ai-cuda-runtime"
flutter build windows --release --no-pub
```

The portable runtime includes CUDA libraries; the target PC needs a compatible
NVIDIA driver. `--backend cpu` prepares a smaller CPU bundle in a separate output
directory. CMake defaults to `build/photo-ai-runtime`; override `PHOTO_AI_RUNTIME`
for other prepared bundles. Copy the entire application folder including
`photo_ai`, not just the EXE. `THERMAL_AI_RUNTIME` overrides the path in tests.
The preparation and installation steps remove known retired model resources when
upgrading an old bundle.

## Focused checks

```powershell
flutter test --no-pub test/ai_super_resolution_test.dart test/realtime_ai_session_test.dart
build/photo-ai-cuda-runtime/python/python.exe tools/photo_ai/test_adapters.py
```

For an end-to-end test on a downloaded 120×90 temperature CSV:

```powershell
$env:THERMAL_SR_SAMPLE='<path to temperature CSV>'
$env:THERMAL_AI_RUNTIME="$PWD/build/photo-ai-cuda-runtime"
$env:THERMAL_AI_RESULTS='build/pft-only-check'
$env:THERMAL_AI_EXPECT_DEVICE='cuda'
flutter test --no-pub tools/check_thermal_ai_models.dart
```

Tests cover latest-frame queuing, stale/disposed jobs, runtime error recovery,
photo model/export selection, measurement invariance, CUDA fallback and model
block progress. These are non-UI checks, not Flutter page or hardware tests.
Earlier multi-model benchmark results remain historical research only in
`docs/thermal_super_resolution_research.md`.

PFT-only validation on November 18, 2026: 12 focused Dart tests and four Python
adapter tests passed, as did the Windows release build. On downloaded photo
`0000000A`, the CUDA end-to-end check reported warm pipeline times of 136 ms (L1)
and 120 ms (TV), with identical repeated RGB and unchanged measurement fields.
Cold process/model startup took 20.2 seconds in that run; this is not steady-state
frame time. Results are in `build/pft-only-check/results.json`. These are host
measurements, not a hardware live-stream FPS claim. Dart analysis had no errors
and retained four existing diagnostics in `realtime_tab.dart` (three unused
widgets and one nullable declaration). No Flutter page tests were performed.
