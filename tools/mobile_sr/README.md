# Android thermal SR experiment

Standalone ARM64 Android probe, independent of the Flutter release. No camera, USB device, service or Internet connection required on the phone. The debug APK contains one normalized sample and its expected output. Use non-sensitive samples if sharing the APK.

## LiteRT experiment

From the repository root on Windows, using a disposable Python environment:

```powershell
py -3.14 -m venv build/mobile-lite-env
build/mobile-lite-env/Scripts/python -m pip install ai-edge-litert==2.3.0 flatbuffers
build/mobile-lite-env/Scripts/python tools/mobile_sr/tiny3x.py <sample-directory> build/mobile-sr/assets
android/gradlew.bat -p tools/mobile_sr/android assembleDebug
adb install -r tools/mobile_sr/android/build/outputs/apk/debug/ThermalSrProbe-debug.apk
adb shell am start -n studio.thermal.srprobe/.Probe
adb logcat -s ThermalSR:I
```

Set ANDROID_HOME to the SDK; build with JDK 17 and Android platform 36. Run on API 24+ ARM64. Open **Thermal SR Probe** to run the benchmark. Both runs reuse the compiled model and buffers, with ten warm-ups and 100 timed samples. Timings include input write, invocation and synchronized output readback; they exclude UI, USB, warm-up and measurement processing. CPU and GPU requests run separately: a failed request is shown, not silently retried under the other label. A successful GPU request does not prove full GPU placement; check device delegate logs and compare latency and numeric error. Repeat under sustained load before enabling live SR.

Input CSVs have columns `x,y,temperature_c` and one complete 120x90 frame each. Each is min-max normalized independently. The two last unique frames in filename order are reserved for validation. The others are reduced by 3x3 area averaging and used to fit a 1x1 output convolution following fixed 3x3 edge filters and ReLU. DepthToSpace produces 3x gray output. The final graph is FP32, 2,248 bytes. It has no learned temperature calibration.

On six distinct local captures (four training, two held out), the 40x30 -> 120x90 surrogate test measured 34.64 and 29.71 dB PSNR versus 34.89 and 29.76 dB for bicubic. This is not ground truth at 360x270. Both native-size host LiteRT/XNNPACK results matched the independent NumPy calculation (max absolute error 0). This model is for testing the runtime; it does not establish a quality advantage.

## PFT export

Use a separate environment, a directory containing the two Windows checkpoint files and manifest, and the checked-in engine. Activate the environment so its bundled flatc launcher is on PATH:

```powershell
py -3.14 -m venv build/mobile-sr-env
build/mobile-sr-env/Scripts/Activate.ps1
python -m pip install executorch==1.6.0
python tools/mobile_sr/probe_pft.py <weights-directory> build/mobile-sr/tv.pt2
python tools/mobile_sr/probe_pft.py <weights-directory> build/mobile-sr/tv-xnnpack.pte --backend xnnpack --verify-pte build/mobile-sr/assets/input.f32
python tools/mobile_sr/probe_pft.py <weights-directory> build/mobile-sr/tv-vulkan.pte --backend vulkan
```

The probe is fixed to 120x90, including symmetric padding, luminance and 3x cropping. The exported PyTorch graph passed eager comparison on a deterministic input. On this Windows host (torch 2.15.0, ExecuTorch 1.6.0), Vulkan lowering failed inside FuseBatchNormPass with mismatched FakeTensorModes. This is a compiler failure, not evidence that a phone lacks Vulkan. PFT is not packaged inside the LiteRT benchmark APK.

XNNPACK compiled a 62,433,516-byte PTE and the host runtime loaded it. Executing the real frame failed at instruction 0:902, aten::alias_copy.out, with incompatible tensor dimension orders (error 0x12). No PTE latency or output-equivalence result is available.

The separate LiteRT probe was verified on a 2510DRK44C (API 36). Its screen showed the bundled 120x90 frame and the 360x270 output read from the requested GPU run. In that launch, CPU and GPU requests took 0.65 and 0.73 ms at P50, respectively. These are single-frame benchmark timings, not live camera frame rates.
