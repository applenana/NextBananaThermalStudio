import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'ai_super_resolution.dart';
import 'photo_ai_progress.dart';
import 'render_pipeline.dart';

/// Continuous input must not debounce or invalidate an in-flight frame merely
/// because a newer frame arrived. Keep one job and overwrite one pending slot.
class RealtimeAiSession extends ChangeNotifier {
  final Future<RenderedFrame> Function(
    PhotoRenderInput,
    PhotoAiProgressCallback,
  )?
  _infer;
  RealtimeAiSession({
    Future<RenderedFrame> Function(PhotoRenderInput, PhotoAiProgressCallback)?
    infer,
  }) : _infer = infer;

  bool enabled = false, busy = false;
  bool _disposed = false;
  int _generation = 0;
  String? _configuration;
  PhotoRenderInput? _pending;
  Float32List? _lastSubmitted;
  RenderedFrame? _result;
  Uint8List? _displayRgb;
  (int, int)? _displaySize;
  PhotoAiProgress? progress;
  String? error;
  int? elapsedMs;

  void setEnabled(bool value) {
    if (enabled == value) return;
    enabled = value;
    clear();
  }

  /// Drop old stream/configuration output, including work still in flight.
  void clear() {
    _generation++;
    _pending = null;
    _lastSubmitted = null;
    _configuration = null;
    _result = null;
    _displayRgb = null;
    _displaySize = null;
    error = null;
    progress = null;
    elapsedMs = null;
    if (!_disposed) notifyListeners();
  }

  void submit(PhotoRenderInput input) {
    if (!enabled || _disposed) return;
    final configuration = jsonEncode([
      input.width,
      input.height,
      input.params.toJson(),
      input.visibleW,
      input.visibleH,
      input.aiModel.id,
      input.aiScale,
    ]);
    if (_configuration != configuration) {
      clear();
      _configuration = configuration;
    }
    // After an error require toggle/configuration change rather than retrying
    // a broken runtime for every incoming sensor frame.
    if (error != null || identical(input.temperatures, _lastSubmitted)) return;
    _lastSubmitted = input.temperatures;
    if (!input.supportsAiScale) {
      error = '此分辨率不支持 PFT 3×，已显示普通画面';
      notifyListeners();
      return;
    }
    _pending = input;
    if (!busy) unawaited(_run());
  }

  Future<void> _run() async {
    if (_disposed || !enabled || busy || _pending == null) return;
    final input = _pending!;
    final generation = _generation;
    _pending = null;
    busy = true;
    progress = const PhotoAiProgress('queued');
    notifyListeners();
    final clock = Stopwatch()..start();
    bool current() => !_disposed && enabled && generation == _generation;
    void report(PhotoAiProgress value) {
      if (current()) {
        progress = value;
        notifyListeners();
      }
    }

    try {
      final result =
          await (_infer?.call(input, report) ??
              input.enhanceAsync(onProgress: report));
      if (current()) {
        _result = result;
        _displayRgb = null;
        _displaySize = null;
        elapsedMs = clock.elapsedMilliseconds;
      }
    } catch (e) {
      if (current()) {
        error = 'AI 失败，已恢复普通画面；关闭后重开可重试：$e';
        _result = null;
        _pending = null;
        _displayRgb = null;
        progress = null;
      }
    } finally {
      busy = false;
      if (!_disposed) {
        notifyListeners();
        if (enabled && _pending != null) unawaited(_run());
      }
    }
  }

  /// Keep the existing canvas/measurement coordinate grid, including recorder
  /// points. PFT infers at 3x; only its RGB is resized for the selected grid.
  RenderedFrame display(RenderedFrame measured) {
    final enhanced = _result;
    if (!enabled || enhanced == null) return measured;
    final size = (measured.width, measured.height);
    if (_displayRgb == null || _displaySize != size) {
      _displayRgb = (enhanced.width, enhanced.height) == size
          ? enhanced.rgb
          : img
                .copyResize(
                  img.Image.fromBytes(
                    width: enhanced.width,
                    height: enhanced.height,
                    bytes: enhanced.rgb.buffer,
                    bytesOffset: enhanced.rgb.offsetInBytes,
                    numChannels: 3,
                  ),
                  width: measured.width,
                  height: measured.height,
                  interpolation: img.Interpolation.linear,
                )
                .getBytes(order: img.ChannelOrder.rgb);
      _displaySize = size;
    }
    return RenderedFrame(
      rgb: _displayRgb!,
      width: measured.width,
      height: measured.height,
      normalizedField: measured.normalizedField,
      temperatureField: measured.temperatureField,
      tMin: measured.tMin,
      tMax: measured.tMax,
      thermalColorScaleRgb: measured.thermalColorScaleRgb,
      hasFiniteTemperatureData: measured.hasFiniteTemperatureData,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    clear();
    super.dispose();
  }
}
