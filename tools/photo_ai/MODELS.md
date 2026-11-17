# Thermal photo AI runtime

This optional **Windows CUDA/CPU** bundle is installed beside the application as
`photo_ai/`. The Flutter model dropdown detects the bundle; missing models are
disabled. It does not download models at application runtime. ESPCN stays native
and is also available on Android. All models modify display luminance only.

## Imported architectures and checkpoints

| Dropdown | Architecture / pinned source | Checkpoint | Native scale |
| --- | --- | --- | --- |
| Thermal-PFT L1 | `guillepinto/THERMAL-PFT-SR`, `644aed807dc9c4c56ad9e9aaa2711a9ccb9106d4`, `basicsr/archs/pft_arch.py` | `SemilleroCV/thermal-pft-light-srx3`, revision `5002f089dcbd43c6835620136e0c0318707276cf` | 3 |
| Thermal-PFT TV | Same PFT architecture | `SemilleroCV/thermal-pft-light-srx3-cross-channel-tv`, revision `98dfd184de8d364d19982190d70c2c692333aaf5` | 3 |
| DRCT-L / PBVS | `Raojiyong/PBVS_TSR`, `2e2e281cea494cb430d9a445460dddad40470b4f`, `drct/archs/DRCT_arch.py` | Author-linked Drive `net_g_model_best.pth`, file ID `1MzYdz63dlql-WdUQsL9eC5AUqNGYedVF` | 8 |
| SwinFuSR no visible | `VisionICLab/SwinFuSR`, `682a2cdf6cd8cd2be25a78d6e1ee07d8e67e5ac4`, `models/network_swinfusionSR.py` | Release `v1.0.0/robust03` | 8 |

Exact download URLs are in `prepare_runtime.py`; SHA-256 values are committed in
`weights-manifest.json`. Downloads use temporary files and are published only
after verification. Every worker model load verifies the hash and loads strictly
matching state dictionaries using `torch.load(weights_only=True)`. No partial
weights, random layers, or ordinary PFT fallback weights are used.

The earlier research note called PBVS_TSR “SwinFIR”; source inspection corrected
this to the author's multi-scale DRCT-L. Its official test path selects the last
output (8×). Earlier 2×/4× heads are not exposed as independent verified models.

## Inference adaptations

- Vendored architecture files retain their original computation. Imports from
  training frameworks are replaced by `vendor/compat.py`; DropPath is inference
  only, registry decorators are no-ops, and PyTorch supplies trunc_normal_.
- PFT's optional custom CUDA sparse matrix kernels are replaced by mathematically
  equivalent batched products with gather/scatter. Unit tests compare these with
  explicit selected-element products. Per-layer CUDA cache purges are removed.
  No CUDA toolkit or custom extension is needed.
- PFT and DRCT expect three-channel images. Normalized **pre-palette** thermal
  intensity is repeated into three channels; the result is converted to luminance
  with weights 0.299/0.587/0.114, so predicted colors never become a new palette.
- PFT/DRCT use symmetric padding to a 32/16 window multiple and exact output
  cropping. Very small images use replicate padding to reach one full window.
- SwinFuSR uses robust03 and a zero guide, matching the author's missing-modality
  evaluation. This option always uses that path, including on devices with RGB;
  it does not assume the visible image is registered to thermal pixels.
- SwinFuSR expects pre-upsampled thermal data. We use PyTorch bicubic 8×,
  align_corners=false, clipped to [0,1]. This differs from upstream's MATLAB-style
  image resize helper. Output is processed in 128-pixel blocks with a 32-pixel
  halo, aligned to its eight-pixel windows. This bounds CPU memory, but is not
  guaranteed identical to full-frame inference and may introduce seams.
- Output is checked for size, finiteness and range. Each output axis is capped at
  1024; supported factors are fixed per model. AI values never feed measurement.

## Runtime and packaging

`worker.py` serves sequential JSON lines over child-process stdin/stdout with
base64 little-endian float32 payloads. Diagnostics go to stderr. Only one model
is held at a time. Flutter shares one queued worker across galleries, enforces a
five-minute response timeout, kills/restarts a failed worker, and releases it
after five idle minutes. EOF from the parent ends the process. Source/preprocessing
and recoloring run in Dart isolates. Preview failures display ordinary rendering
with an error; requested AI exports fail explicitly. Model and scale are captured
at export start and are part of the preview cache key and output filename.

Prepare with Windows Python 3.13:

```powershell
python tools/photo_ai/prepare_runtime.py --backend cuda --output build/photo-ai-cuda-runtime
cmake -S windows -B build/windows/x64 -DPHOTO_AI_RUNTIME="$PWD/build/photo-ai-cuda-runtime"
flutter build windows --release --no-pub
```

The script uses a portable Python 3.13.3 interpreter and defaults to CUDA
(torch 2.11.0+cu128, numpy 2.5.5, einops 0.8.2). `--backend cpu` prepares the
smaller CPU-only bundle (torch 2.15.0+cpu). It does not modify global
packages. CMake copies `build/photo-ai-runtime` when present; without it, the app
still builds and clearly disables these four models. For an existing installation,
copy the complete bundle to `<application>/photo_ai`; don't copy only the EXE.
`THERMAL_AI_RUNTIME` overrides its location for developer tests.

CUDA is selected automatically when available. CUDA allocation/driver/kernel
failures retry once on CPU and retain a fallback reason; unrelated model errors
remain errors. FP32 is retained with TF32 disabled. ESPCN continues to use its
fast native CPU implementation. A CUDA runtime includes the CUDA libraries;
the target PC still needs a compatible NVIDIA driver. No separate toolkit is
needed to use the prepared bundle. CPU-only and CUDA bundles must be prepared
in separate output directories. CMake's `PHOTO_AI_RUNTIME` cache path selects
the bundle to package when using a non-default output directory.

The progress protocol sends flushed JSON `event: progress` records before the
final result. Loading/preparation/coloring use indeterminate progress; PFT and
DRCT report completed top-level model blocks, and SwinFuSR reports completed
image tiles. Percentages describe work units in that stage, not predicted time.
CUDA synchronization precedes completed-work events. Both galleries show the
backend and progress, including exports; stale preview events cannot replace
the selected photo/model's progress. The five-minute request deadline includes
all progress events. Worker reuse avoids repeated interpreter/CUDA startup.

## Validation, November 18, 2026

The full Dart-to-portable-worker pipeline was run on the last downloaded CB360
photo, `0000000A` (120×90), using the same display parameters and plasma palette:

| Model | Output | End-to-end pipeline time |
| --- | --- | --- |
| ESPCN | 240×180 | 79 ms |
| Thermal-PFT L1 | 360×270 | 10794 ms |
| Thermal-PFT TV | 360×270 | 3433 ms |
| DRCT-L | 960×720 | 11788 ms |
| SwinFuSR robust03 | 960×720 | 61917 ms |

Single CPU runs, not a benchmark. L1 includes initial process/PyTorch startup;
each changed model includes load/hash time. PNG encoding and page presentation
are excluded. These historical baseline measurements used CPU only.

All source temperatures, ordinary measurement arrays, ranges and legends matched
before/after inference. Full output images and summary are generated under
`build/thermal-ai-comparison/` by `tools/check_thermal_ai_models.dart`. Exported
image inspection showed smoother DRCT-L boundaries, PFT boundary/ringing artifacts,
and limited extra detail from SwinFuSR despite its high CPU cost. There is no
high-resolution truth for this photo; visual changes do not establish accuracy.
No Flutter page/UI tests or Android builds were performed.

### CUDA validation on RTX 5080

The same `0000000A` photo and display parameters were tested through the complete
Dart/isolate/portable-worker pipeline with torch 2.11.0+cu128 and NVIDIA driver
610.62. CUDA matrix execution and all four real model executions succeeded on
the RTX 5080 (compute capability 12.0), without fallback.

| Model | First request / model load | Immediate repeat, model retained |
| --- | --- | --- |
| ESPCN (native CPU) | 85 ms | 62 ms |
| Thermal-PFT L1 | 2165 ms | 135 ms |
| Thermal-PFT TV | 554 ms | 121 ms |
| DRCT-L | 9166 ms | 546 ms |
| SwinFuSR robust03 | 4204 ms | 3980 ms |

Single runs; L1 includes worker/PyTorch/CUDA startup. Each model's first request
includes weight verification and loading, and all times include rendering and
progress delivery but exclude PNG encoding/page painting. DRCT-L's first load
remains expensive. Repeats perform inference again, without using gallery result
caches. The benchmark intentionally retains the baseline's bilateral setting
for comparison; CB360's application default is now bilateral filtering off.

Progress counts ran from zero to the actual completed block/tile count, final
backend was CUDA, repeated RGB outputs matched, and all measured temperature
fields/ranges/legends were unchanged. Compared with the previous CPU PNGs,
maximum mean absolute RGB channel error across the four models was 0.00021 on
the 0–255 scale. This checks computational consistency, not reconstructed detail
accuracy. Artifacts: `build/thermal-ai-cuda-comparison/`.

Reproduce the end-to-end test with `THERMAL_SR_SAMPLE` pointing to the temperature
CSV and `THERMAL_SR_LIBRARY` to the native ESPCN DLL, then:

```powershell
$env:THERMAL_AI_RUNTIME="$PWD/build/photo-ai-cuda-runtime"
$env:THERMAL_AI_RESULTS='build/thermal-ai-cuda-comparison'
$env:THERMAL_AI_EXPECT_DEVICE='cuda'
$env:THERMAL_AI_BASELINE='build/thermal-ai-comparison'
flutter test --no-pub tools/check_thermal_ai_models.dart
```

Focused validation also covers CPU retry for CUDA failures, propagation of
unrelated failures, hook cleanup, stale model progress, export failure cleanup,
measurement invariance and native ESPCN reference output. No Flutter page tests.

## Licenses

Architecture licenses are reproduced in `PFT-LICENSE.txt` (Apache-2.0),
`DRCT-LICENSE.txt` (MIT), and `SwinFuSR-LICENSE.txt` (Apache-2.0), and registered in
the app. Both PFT model cards declare Apache-2.0. PBVS and SwinFuSR weights are
author-linked releases; no separate weight license was supplied in those downloads.
The portable interpreter and dependency distributions retain their license files.
