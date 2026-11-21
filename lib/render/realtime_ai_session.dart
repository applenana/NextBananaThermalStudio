import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
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
  PhotoAiProgress? progress;
  PhotoAiProgress? lastCompletedProgress;
  final Stopwatch _outputClock = Stopwatch();
  int? _lastOutputUs;
  double? outputFps;
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
    error = null;
    progress = null;
    elapsedMs = null;
    lastCompletedProgress = null;
    outputFps = null;
    _lastOutputUs = null;
    _outputClock.reset();
    _outputClock.start();
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
      input.backend.name,
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
      error = '此分辨率不支持 ${input.aiModel.label} 3×，已显示普通画面';
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
        if (value.stage == 'complete') lastCompletedProgress = value;
        notifyListeners();
      }
    }

    try {
      final result =
          await (_infer?.call(input, report) ??
              input.enhanceAsync(onProgress: report));
      if (current()) {
        _result = result;
        elapsedMs = clock.elapsedMilliseconds;
        final now = _outputClock.elapsedMicroseconds;
        final previous = _lastOutputUs;
        if (previous != null && now > previous) {
          final instantaneous = 1000000 / (now - previous);
          outputFps = outputFps == null
              ? instantaneous
              : outputFps! * 0.75 + instantaneous * 0.25;
        }
        _lastOutputUs = now;
      }
    } catch (e) {
      if (current()) {
        error = 'AI 失败，已恢复普通画面；关闭后重开可重试：$e';
        _result = null;
        _pending = null;
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

  /// Full native AI RGB for display only. The canvas retains its independent
  /// measured frame for temperatures, markers and recorder coordinates.
  RenderedFrame? get enhancedFrame => enabled ? _result : null;

  @override
  void dispose() {
    _disposed = true;
    clear();
    super.dispose();
  }
}
