import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'ai_super_resolution.dart';
import 'render_pipeline.dart';

/// One in-flight inference and one latest pending input per gallery preview.
/// Slider changes are debounced, old results never replace a newly selected photo.
class PhotoAiSession extends ChangeNotifier {
  final Future<RenderedFrame> Function(PhotoRenderInput) _infer;
  PhotoAiSession({Future<RenderedFrame> Function(PhotoRenderInput)? infer})
    : _infer = infer ?? ((input) => Isolate.run(input.enhance));
  int _scale = 0;
  int get scale => _scale;
  bool get enabled => _scale != 0;
  bool busy = false;
  bool _disposed = false;
  String? error;
  int? elapsedMs;
  Timer? _debounce;
  Object? _wanted, _completed;
  PhotoRenderInput? _pending;
  RenderedFrame? _result;

  Object _key(PhotoRenderInput input) => (
    input.temperatures,
    input.width,
    input.height,
    jsonEncode(input.params.toJson()),
    input.visibleRgb,
    input.visibleW,
    input.visibleH,
    input.min,
    input.max,
    input.aiScale,
  );

  void setScale(int value) {
    if (value != 0 && !photoAiScales.contains(value)) {
      throw ArgumentError.value(value, 'scale', 'Supported: 0, 2, 4, 8');
    }
    if (_scale == value) return;
    _scale = value;
    _wanted = null;
    _completed = null;
    _result = null;
    _pending = null;
    error = null;
    elapsedMs = null;
    _debounce?.cancel();
    notifyListeners();
  }

  RenderedFrame preview(PhotoRenderInput input) {
    if (!enabled) return input.render();
    input = input.withAiScale(scale);
    if (!input.supportsAiScale) {
      _wanted = null;
      _pending = null;
      _debounce?.cancel();
      error = '当前照片不支持 $scale× AI 超分，请选择较低倍率（输出每边最多 1024）';
      elapsedMs = null;
      return input.render();
    }
    final key = _key(input);
    if (_completed == key && _result != null) return _result!;
    if (_wanted != key) {
      _wanted = key;
      _pending = input;
      error = null;
      elapsedMs = null;
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 180), _run);
    }
    return input.render(scale: scale);
  }

  Future<void> _run() async {
    if (busy || _disposed || !enabled || _pending == null) return;
    final input = _pending!;
    final key = _key(input);
    _pending = null;
    busy = true;
    notifyListeners();
    final clock = Stopwatch()..start();
    try {
      final result = await _infer(input);
      if (!_disposed && enabled && _wanted == key) {
        _completed = key;
        _result = result;
        elapsedMs = clock.elapsedMilliseconds;
      }
    } catch (e) {
      if (!_disposed && enabled && _wanted == key) {
        error = 'AI 超分失败，已显示普通预览：$e';
      }
    } finally {
      busy = false;
      if (!_disposed) {
        notifyListeners();
        if (_pending != null) unawaited(_run());
      }
    }
  }

  Future<RenderedFrame> export(PhotoRenderInput input, {int? scale}) async {
    final selectedScale = scale ?? this.scale;
    if (selectedScale == 0) return input.render();
    input = input.withAiScale(selectedScale);
    if (!input.supportsAiScale) {
      throw const FormatException('当前照片不支持此 AI 倍率（输出每边最多 1024）');
    }
    if (_completed == _key(input) && _result != null) return _result!;
    // Export never silently substitutes a regular image for requested AI output.
    return _infer(input);
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _pending = null;
    super.dispose();
  }
}
