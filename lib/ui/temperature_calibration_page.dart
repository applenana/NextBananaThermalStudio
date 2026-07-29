/// Guided multi-point linear temperature calibration.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../protocol/temperature_calibration.dart';
import '../render/render_pipeline.dart';
import 'banana_toast.dart';
import 'widgets/thermal_canvas.dart';

const int _calibrationSampleFrameTarget = 24;
const int _calibrationMinimumUsableFrames = 8;

Future<void> openTemperatureCalibrationPage(BuildContext context) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => const TemperatureCalibrationPage(),
    ),
  );
}

class TemperatureCalibrationPage extends StatefulWidget {
  const TemperatureCalibrationPage({super.key});

  @override
  State<TemperatureCalibrationPage> createState() =>
      _TemperatureCalibrationPageState();
}

class _TemperatureCalibrationPageState
    extends State<TemperatureCalibrationPage> {
  final TextEditingController _referenceController = TextEditingController();
  final List<CalibrationSample> _samples = [];

  TemperatureCalibration? _baseline;
  bool _loading = false;
  bool _sampling = false;
  bool _applying = false;
  int _sampleProgress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshCalibration());
  }

  @override
  void dispose() {
    _referenceController.dispose();
    super.dispose();
  }

  Future<void> _refreshCalibration() async {
    if (_loading || _sampling || _applying) return;
    final app = context.read<AppState>();
    if (app.status != ConnectionStatus.connected) {
      setState(() => _error = '请先连接热成像设备，再读取校准参数。');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    if (!app.thermalStreamEnabled) {
      app.setThermalStream(true);
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    try {
      final calibration = await app.fetchTemperatureCalibration();
      if (!mounted) return;
      setState(() {
        _baseline = calibration;
        _samples.clear();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _capturePoint() async {
    if (_sampling || _applying) return;
    final baseline = _baseline;
    if (baseline == null) {
      setState(() => _error = '尚未读取设备当前校准参数。');
      return;
    }
    final reference = double.tryParse(_referenceController.text.trim());
    if (reference == null || !reference.isFinite) {
      setState(() => _error = '请输入有效的参考温度。');
      return;
    }
    if (reference < -40 || reference > 300) {
      setState(() => _error = '参考温度应在 -40℃ 到 300℃ 之间。');
      return;
    }

    final app = context.read<AppState>();
    if (app.status != ConnectionStatus.connected) {
      setState(() => _error = '设备连接已断开。');
      return;
    }
    if (!app.thermalStreamEnabled) app.setThermalStream(true);
    if (app.thermalFrame == null) {
      setState(() => _error = '正在等待热成像首帧，请稍后重试。');
      return;
    }

    final values = <double>[];
    Object? lastFrame = app.thermalFrame;
    final done = Completer<void>();
    Timer? timeout;

    void listener() {
      final frame = app.thermalFrame;
      if (frame == null || identical(frame, lastFrame)) return;
      lastFrame = frame;
      final value = centerRoiTrimmedMean(frame);
      if (value == null) return;
      values.add(value);
      if (mounted) {
        setState(() => _sampleProgress = values.length);
      }
      if (values.length >= _calibrationSampleFrameTarget && !done.isCompleted) {
        done.complete();
      }
    }

    setState(() {
      _sampling = true;
      _sampleProgress = 0;
      _error = null;
    });
    app.addListener(listener);
    timeout = Timer(const Duration(seconds: 8), () {
      if (!done.isCompleted) done.complete();
    });

    try {
      await done.future;
    } finally {
      timeout.cancel();
      app.removeListener(listener);
    }
    if (!mounted) return;

    if (values.length < _calibrationMinimumUsableFrames) {
      setState(() {
        _sampling = false;
        _error = '有效帧不足（${values.length} 帧），请保持设备稳定并确认推流正常。';
      });
      return;
    }

    final mean = values.reduce((a, b) => a + b) / values.length;
    var variance = 0.0;
    for (final value in values) {
      final delta = value - mean;
      variance += delta * delta;
    }
    final standardDeviation = math.sqrt(variance / values.length);
    setState(() {
      _samples.add(
        CalibrationSample(
          measured: mean,
          reference: reference,
          standardDeviation: standardDeviation,
          frameCount: values.length,
        ),
      );
      _sampling = false;
      _sampleProgress = 0;
      _referenceController.clear();
    });
  }

  Future<void> _applyFit(LinearCalibrationFit fit) async {
    if (_applying || _sampling) return;
    if (!fit.calibration.isWithinDeviceLimits) {
      setState(() {
        _error = '拟合结果超出设备安全范围，请检查参考温度与取样点。';
      });
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.tune_rounded),
        title: const Text('写入线性校准参数？'),
        content: Text(
          '新公式：T = 原始温度 × '
          '${fit.calibration.gain.toStringAsFixed(6)} '
          '${_signed(fit.calibration.offset, digits: 3)}℃\n\n'
          '参数会立即生效并保存到设备；已有的原始照片数据不会被改写。'
          '${fit.measuredSpan < 10 ? '\n\n当前取样跨度较小，建议达到 10℃ 以上后再写入。' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('写入并保存'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      final result = await context.read<AppState>().applyTemperatureCalibration(
        gain: fit.calibration.gain,
        offset: fit.calibration.offset,
      );
      if (!mounted) return;
      setState(() {
        _baseline = result;
        _samples.clear();
      });
      BananaToast.show(context, '线性校准参数已写入并保存');
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _resetCalibration() async {
    if (_applying || _sampling) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.restart_alt_rounded),
        title: const Text('恢复默认校准？'),
        content: const Text('设备将恢复 T = 原始温度 × 1 + 0℃，并立即保存。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      final result = await context
          .read<AppState>()
          .resetTemperatureCalibration();
      if (!mounted) return;
      setState(() {
        _baseline = result;
        _samples.clear();
      });
      BananaToast.show(context, '已恢复默认校准参数');
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  LinearCalibrationFit? get _fit {
    final baseline = _baseline;
    if (baseline == null) return null;
    return fitTemperatureCalibration(
      currentCalibration: baseline,
      samples: _samples,
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final fit = _fit;
    final busy = _loading || _sampling || _applying;

    return Scaffold(
      appBar: AppBar(
        title: const Text('热成像线性校准'),
        actions: [
          IconButton(
            tooltip: '重新读取设备参数',
            onPressed: busy ? null : _refreshCalibration,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 860;
            final preview = _buildPreviewPanel(app);
            final workflow = _buildWorkflowPanel(app, fit);
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1180),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    _buildIntro(),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      _ErrorBanner(message: _error!),
                    ],
                    const SizedBox(height: 12),
                    if (wide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 5, child: preview),
                          const SizedBox(width: 14),
                          Expanded(flex: 6, child: workflow),
                        ],
                      )
                    else ...[
                      preview,
                      const SizedBox(height: 12),
                      workflow,
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildIntro() {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.primaryContainer.withValues(alpha: 0.42),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.science_outlined, color: scheme.primary),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                '使用两个或更多已知温度点拟合 T参考 = k × T设备 + b。'
                '让均匀恒温目标覆盖画面中央框，温度稳定后输入参考值并取样。'
                '推荐取样点跨度至少 10℃，跨度越大越可靠。',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewPanel(AppState app) {
    final scheme = Theme.of(context).colorScheme;
    RenderedFrame? rendered;
    if (app.thermalFrame != null) {
      rendered = renderPipeline(
        thermalFrame: app.thermalFrame!,
        srcW: 32,
        srcH: 24,
        params: app.renderParams,
      );
    }
    final liveRoi = app.thermalFrame == null
        ? null
        : centerRoiTrimmedMean(app.thermalFrame!);

    return Column(
      children: [
        Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Row(
                  children: [
                    const Icon(Icons.center_focus_strong_rounded, size: 20),
                    const SizedBox(width: 8),
                    const Text(
                      '中央取样区',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    _LiveValueChip(value: liveRoi),
                  ],
                ),
              ),
              AspectRatio(
                aspectRatio: 4 / 3,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ThermalCanvas(
                      frame: rendered,
                      showCursorTemp: false,
                      placeholder: app.status == ConnectionStatus.connected
                          ? '等待热成像推流…'
                          : '设备未连接',
                    ),
                    IgnorePointer(
                      child: Center(
                        child: FractionallySizedBox(
                          widthFactor: 0.25,
                          heightFactor: 1 / 3,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.white, width: 2),
                              borderRadius: BorderRadius.circular(5),
                              boxShadow: const [
                                BoxShadow(color: Colors.black54, blurRadius: 2),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.memory_rounded, size: 20),
                    const SizedBox(width: 8),
                    const Text(
                      '设备当前参数',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    if (_loading)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_baseline == null)
                  Text(
                    app.status == ConnectionStatus.connected ? '尚未读取' : '未连接',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  )
                else ...[
                  _ParameterRow(
                    label: '增益 k',
                    value: _baseline!.gain.toStringAsFixed(6),
                  ),
                  const SizedBox(height: 8),
                  _ParameterRow(
                    label: '偏移 b',
                    value: '${_baseline!.offset.toStringAsFixed(3)} ℃',
                  ),
                  const SizedBox(height: 8),
                  _ParameterRow(
                    label: '存储状态',
                    value: _baseline!.persisted ? '已保存到设备' : '设备未确认',
                  ),
                  const SizedBox(height: 8),
                  _ParameterRow(
                    label: '协议模式',
                    value:
                        _baseline!.protocol ==
                            TemperatureCalibrationProtocol.atomicV1
                        ? 'v1 原子协议'
                        : '旧版兼容模式',
                  ),
                  if (_baseline!.protocol ==
                      TemperatureCalibrationProtocol.legacy) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.tertiaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '旧固件需分两次写入，无法原子更新。上位机会在保存后自动回读校验；'
                        '条件允许时建议升级固件。',
                        style: TextStyle(
                          color: scheme.onTertiaryContainer,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: (_baseline == null || _sampling || _applying)
                      ? null
                      : _resetCalibration,
                  icon: const Icon(Icons.restart_alt_rounded, size: 18),
                  label: const Text('恢复默认系数'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWorkflowPanel(AppState app, LinearCalibrationFit? fit) {
    return Column(
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    Icon(Icons.add_chart_rounded, size: 20),
                    SizedBox(width: 8),
                    Text(
                      '1. 添加参考温点',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _referenceController,
                  enabled: !_sampling && !_applying && _baseline != null,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _capturePoint(),
                  decoration: const InputDecoration(
                    labelText: '参考温度',
                    hintText: '例如 25.0',
                    suffixText: '℃',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed:
                      (_sampling ||
                          _applying ||
                          _baseline == null ||
                          app.thermalFrame == null)
                      ? null
                      : _capturePoint,
                  icon: _sampling
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.center_focus_strong_rounded),
                  label: Text(
                    _sampling
                        ? '正在取样 $_sampleProgress / '
                              '$_calibrationSampleFrameTarget'
                        : '采集中央区域',
                  ),
                ),
                if (_sampling) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: _sampleProgress / _calibrationSampleFrameTarget,
                  ),
                ],
                const SizedBox(height: 14),
                if (_samples.isEmpty)
                  const _EmptySamples()
                else
                  for (var i = 0; i < _samples.length; i++) ...[
                    _SampleTile(
                      index: i,
                      sample: _samples[i],
                      residual: fit?.residuals[i],
                      onDelete: _sampling || _applying
                          ? null
                          : () => setState(() => _samples.removeAt(i)),
                    ),
                    if (i != _samples.length - 1) const SizedBox(height: 8),
                  ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _buildFitResult(fit),
          ),
        ),
      ],
    );
  }

  Widget _buildFitResult(LinearCalibrationFit? fit) {
    final scheme = Theme.of(context).colorScheme;
    if (_samples.length < 2) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.functions_rounded, size: 20),
              SizedBox(width: 8),
              Text('2. 拟合并写入', style: TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          SizedBox(height: 14),
          Text('至少添加两个不同温度的参考点后，才会计算线性系数。'),
        ],
      );
    }
    if (fit == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 20),
              SizedBox(width: 8),
              Text('无法稳定拟合', style: TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '设备测量温度跨度不足 1℃。请删除重复点，并在更高或更低的参考温度下重新取样。',
            style: TextStyle(color: scheme.error),
          ),
        ],
      );
    }

    final withinLimits = fit.calibration.isWithinDeviceLimits;
    final stableSamples = _samples.every(
      (sample) => sample.standardDeviation <= 0.2,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Row(
          children: [
            Icon(Icons.functions_rounded, size: 20),
            SizedBox(width: 8),
            Text('2. 拟合并写入', style: TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            'T = 原始温度 × ${fit.calibration.gain.toStringAsFixed(6)} '
            '${_signed(fit.calibration.offset, digits: 3)}℃',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _MetricChip(
              label: '取样跨度',
              value: '${fit.measuredSpan.toStringAsFixed(1)}℃',
              good: fit.measuredSpan >= 10,
            ),
            _MetricChip(
              label: 'RMSE',
              value: '${fit.rootMeanSquareError.toStringAsFixed(3)}℃',
              good: fit.rootMeanSquareError <= 0.5,
            ),
            _MetricChip(
              label: 'R²',
              value: fit.rSquared.toStringAsFixed(4),
              good: fit.rSquared >= 0.99,
            ),
            _MetricChip(
              label: '取样稳定性',
              value: stableSamples ? '良好' : '有波动',
              good: stableSamples,
            ),
          ],
        ),
        if (fit.measuredSpan < 10 || !stableSamples || !withinLimits) ...[
          const SizedBox(height: 12),
          Text(
            !withinLimits
                ? '结果超出设备安全范围，不能写入。请检查参考值是否输入错误。'
                : fit.measuredSpan < 10
                ? '取样跨度小于 10℃，斜率对测量噪声较敏感，建议增加更远的温点。'
                : '部分温点波动超过 0.2℃，建议待目标稳定后重新取样。',
            style: TextStyle(
              color: !withinLimits ? scheme.error : scheme.tertiary,
            ),
          ),
        ],
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: (_sampling || _applying || !withinLimits)
              ? null
              : () => _applyFit(fit),
          icon: _applying
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.save_rounded),
          label: Text(_applying ? '正在写入…' : '写入并保存到设备'),
        ),
      ],
    );
  }
}

/// Returns a 10%-trimmed mean from the center 8×8 pixels of a 32×24 frame.
/// The center region avoids most background leakage when the user aims a
/// uniform reference target at the crosshair.
double? centerRoiTrimmedMean(Float32List frame) {
  if (frame.length < 32 * 24) return null;
  const width = 32;
  const startX = 12;
  const startY = 8;
  const roiWidth = 8;
  const roiHeight = 8;
  final values = <double>[];
  for (var y = startY; y < startY + roiHeight; y++) {
    for (var x = startX; x < startX + roiWidth; x++) {
      final value = frame[y * width + x];
      if (value.isFinite && value >= -100 && value <= 500) {
        values.add(value);
      }
    }
  }
  if (values.length < 16) return null;
  values.sort();
  final trim = math.max(1, values.length ~/ 10);
  final kept = values.sublist(trim, values.length - trim);
  return kept.reduce((a, b) => a + b) / kept.length;
}

String _friendlyError(Object error) {
  if (error is TimeoutException) return error.message ?? '设备响应超时';
  if (error is FormatException) return error.message;
  if (error is StateError) return error.message;
  if (error is RangeError) return error.message?.toString() ?? '参数超出范围';
  return error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
}

String _signed(double value, {int digits = 2}) {
  final sign = value >= 0 ? '+' : '−';
  return '$sign ${value.abs().toStringAsFixed(digits)}';
}

class _LiveValueChip extends StatelessWidget {
  const _LiveValueChip({required this.value});
  final double? value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        value == null ? '--.- ℃' : '${value!.toStringAsFixed(2)} ℃',
        style: TextStyle(
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _ParameterRow extends StatelessWidget {
  const _ParameterRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
        SelectableText(
          value,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _EmptySamples extends StatelessWidget {
  const _EmptySamples();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '还没有参考点。每次取样会对中央区域连续采集 '
        '$_calibrationSampleFrameTarget 帧。',
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

class _SampleTile extends StatelessWidget {
  const _SampleTile({
    required this.index,
    required this.sample,
    required this.residual,
    required this.onDelete,
  });

  final int index;
  final CalibrationSample sample;
  final double? residual;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final stable = sample.standardDeviation <= 0.2;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 15,
            backgroundColor: scheme.primaryContainer,
            child: Text(
              '${index + 1}',
              style: TextStyle(
                color: scheme.onPrimaryContainer,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '设备 ${sample.measured.toStringAsFixed(2)}℃  →  '
                  '参考 ${sample.reference.toStringAsFixed(2)}℃',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  'σ ${sample.standardDeviation.toStringAsFixed(3)}℃ · '
                  '${sample.frameCount} 帧'
                  '${residual == null ? '' : ' · 残差 ${_signed(residual!, digits: 3)}℃'}',
                  style: TextStyle(
                    color: stable ? scheme.onSurfaceVariant : scheme.tertiary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '删除此温点',
            onPressed: onDelete,
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.label,
    required this.value,
    required this.good,
  });

  final String label;
  final String value;
  final bool good;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = good ? Colors.green : scheme.tertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$label  $value',
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
