# Thermal-PFT display super-resolution

The optional **Windows CUDA/CPU** bundle is installed on demand into
`%LOCALAPPDATA%/BananaThermalStudio/ai/photo_ai_v1`. Legacy bundles beside the
application in `photo_ai/` remain supported. Only Thermal-PFT L1 and TV checkpoints remain. Both infer at native
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
The header shows actual block progress, backend, the native displayed AI dimensions
and the previous job duration; the first job explicitly indicates ordinary preview.
It also shows smoothed completed-output FPS (not sensor FPS). Hover the switch
for the previous job's preprocessing, model inference and coloring durations.
Timings include CPU dispatch/readback in inference; they are not CUDA-event GPU-only times.

The inference attention mask caches only the latest padded shape/device, avoiding
repeated CPU construction and upload. Block progress uses CUDA event completion
queries instead of a device synchronization after each block. The ordinary live
render caches the latest source/parameters/visible frame, so AI progress callbacks
do not rerender an unchanged sensor image. Both normal and fullscreen views use it.
FP32 and the existing weights remain unchanged; no batching adds frame latency.
See `docs/ai_performance_20261118.md` for the measured scope and remaining limits.

Live display uses the latest completed AI RGB while measured temperatures,
markers and legend continue updating from the current sensor frame. AI image
updates therefore lag the measurements by the inference/queue time; this is not
an increase in sensor rate or true measurement resolution. The canvas accepts the native 3× RGB separately from the measurement grid,
without shrinking it to the ordinary upsample size. Bilinear screen scaling
avoids magnifying output pixels into blocks. Measurement/recording coordinates
do not move when AI is toggled. There is no AI change to captured raw photo/video data. Normal and
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

Release CI publishes the CUDA/CPU runtime separately from Setup and the portable
application ZIP. `package_runtime.py` streams a ZIP64 archive into ordered 1 GiB
parts (`photo-ai-windows-x64.zip.001`, etc.) and a JSON manifest. Every release
asset is checked to be below 2 GiB. The matching app embeds the manifest SHA-256
with `AI_RUNTIME_MANIFEST_SHA256` and uses `APP_RELEASE_VERSION` to fetch only
that tag's assets over HTTPS. No latest-version lookup or user-supplied URLs are
used for executable downloads.

The startup offer runs after the app update check, only for a missing runtime
on Windows x64, Windows 10+, at least 8 GiB visible RAM, a writable user directory,
and enough disk space (two compressed copies + unpacked size + 1 GiB reserve).
The dialog displays download size, disk requirements, destination and detected
GPU. It downloads nothing beyond the small manifest until the user confirms.
The user may decline or disable automatic offers; manual installation remains
available in Settings, live display and photo controls. No administrator or
system Python installation is required. CUDA support is checked after install;
other machines retain CPU inference, which may be too slow for live use.

Each downloaded part is checked for exact length and SHA-256. Cancelled/failed
attempts reuse complete verified parts on retry (partial parts restart). A
separate staging directory receives extraction, with path/link/size checks.
`check_runtime.py` verifies both model hashes and performs a CPU inference before
activation. An existing installation is preserved if validation fails. Activation
refreshes the model controls and clears the cached CUDA probe without restarting
the app. Successful installation removes download/staging files. The user-owned
runtime persists across app upgrades and uninstallation; its folder may be
removed manually when the app is closed. Offline/missing release assets suppress
the automatic offer; the manual dialog displays the error and allows retry.

Local development builds without both release defines do not download runtime
assets. For a local runtime, prepare using Windows Python 3.13:

```powershell
python tools/photo_ai/prepare_runtime.py --backend cuda --output build/photo-ai-cuda-runtime
cmake -S windows -B build/windows/x64 -DBUNDLE_PHOTO_AI_RUNTIME=ON -DPHOTO_AI_RUNTIME="$PWD/build/photo-ai-cuda-runtime"
flutter build windows --release --no-pub
```

The portable runtime includes CUDA libraries; the target PC needs a compatible
NVIDIA driver. `--backend cpu` prepares a smaller CPU bundle in a separate output
directory. Bundling is off by default; `BUNDLE_PHOTO_AI_RUNTIME=ON` is for local
use only. CMake defaults to `build/photo-ai-runtime`; override `PHOTO_AI_RUNTIME`
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
