/// Guided automatic piecewise temperature calibration.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../calibration/calibration_workspace.dart';
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
  final TextEditingController _breakpointController = TextEditingController();
  final List<CalibrationSample> _samples = [];
  final CalibrationDraftStore _draftStore = const CalibrationDraftStore();
  final CalibrationFitTask _fitTask = CalibrationFitTask();

  CalibrationCurve? _baseline;
  CalibrationFitOptions _options = const CalibrationFitOptions();
  PiecewiseCalibrationFit? _fit;
  bool _loading = false;
  bool _sampling = false;
  bool _fitting = false;
  bool _applying = false;
  int _sampleProgress = 0;
  String? _error;
  String? _notice;
  Timer? _fitDebounce;
  Timer? _draftDebounce;
  int _fitGeneration = 0;

  bool get _busy => _loading || _sampling || _applying;
  String get _deviceKey {
    final app = context.read<AppState>();
    final serial = app.deviceSerial?.trim();
    if (serial != null && serial.isNotEmpty) return serial;
    return app.currentPort ?? 'unknown_device';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshCalibration());
  }

  @override
  void dispose() {
    _fitDebounce?.cancel();
    _draftDebounce?.cancel();
    _fitTask.cancel();
    _referenceController.dispose();
    _breakpointController.dispose();
    super.dispose();
  }

  Future<void> _refreshCalibration() async {
    if (_busy) return;
    final app = context.read<AppState>();
    if (app.status != ConnectionStatus.connected) {
      setState(() => _error = '请先连接热成像设备，再读取校准参数。');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _notice = null;
    });
    if (!app.thermalStreamEnabled) {
      app.setThermalStream(true);
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    try {
      final curve = await app.fetchTemperatureCalibrationCurve();
      final draft = await _draftStore.load(_deviceKey);
      if (!mounted) return;
      setState(() {
        _baseline = curve;
        _samples
          ..clear()
          ..addAll(draft?.samples ?? const []);
        _options = draft?.options ?? const CalibrationFitOptions();
        _breakpointController.text = _options.manualBreakpoints
            .map((value) => value.toStringAsFixed(2))
            .join(', ');
        if (draft != null &&
            draft.baselineCrc32 != null &&
            draft.baselineCrc32 != curve.crc32) {
          _notice = '已恢复此设备的本地草稿；设备校准曲线已变化，含原始温度的样本可继续使用。';
        } else if (draft != null && draft.samples.isNotEmpty) {
          _notice = '已恢复此设备的 ${draft.samples.length} 个校准温点。';
        }
      });
      _scheduleFit(immediate: true);
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _capturePoint() async {
    if (_sampling || _applying || _baseline == null) return;
    final reference = double.tryParse(_referenceController.text.trim());
    if (reference == null || !reference.isFinite) {
      setState(() => _error = '请输入有效的参考温度。');
      return;
    }
    if (reference < -100 || reference > 500) {
      setState(() => _error = '参考温度应在 -100℃ 到 500℃ 之间。');
      return;
    }
    final app = context.read<AppState>();
    if (app.status != ConnectionStatus.connected || app.thermalFrame == null) {
      setState(() => _error = '正在等待热成像数据，请稍后重试。');
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
      final value = centerRoiTrimmedMean(
        frame,
        width: app.thermalWidth,
        height: app.thermalHeight,
      );
      if (value == null) return;
      values.add(value);
      if (mounted) setState(() => _sampleProgress = values.length);
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
          rawInput: _baseline!.invert(mean),
          standardDeviation: standardDeviation,
          frameCount: values.length,
        ),
      );
      _sampling = false;
      _sampleProgress = 0;
      _referenceController.clear();
    });
    _dataChanged();
  }

  void _dataChanged() {
    _scheduleFit();
    _scheduleDraftSave();
  }

  void _scheduleFit({bool immediate = false}) {
    _fitDebounce?.cancel();
    if (_baseline == null || _samples.length < 2) {
      _fitTask.cancel();
      if (mounted) {
        setState(() {
          _fit = null;
          _fitting = false;
        });
      }
      return;
    }
    _fitDebounce = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 220),
      _runFit,
    );
  }

  Future<void> _runFit() async {
    final baseline = _baseline;
    if (baseline == null || _samples.length < 2) return;
    final generation = ++_fitGeneration;
    setState(() {
      _fitting = true;
      _error = null;
    });
    try {
      final result = await _fitTask.start(
        currentCurve: baseline,
        samples: List<CalibrationSample>.from(_samples),
        options: _options,
      );
      if (!mounted || generation != _fitGeneration) return;
      setState(() {
        _fit = result;
        _fitting = false;
        if (result == null) _error = '当前温点无法形成稳定校准曲线，请检查重复点和温度跨度。';
      });
      _scheduleDraftSave();
    } catch (error) {
      if (mounted && generation == _fitGeneration) {
        setState(() {
          _fitting = false;
          _error = _friendlyError(error);
        });
      }
    }
  }

  void _cancelFit() {
    _fitGeneration++;
    _fitTask.cancel();
    setState(() => _fitting = false);
  }

  void _scheduleDraftSave() {
    _draftDebounce?.cancel();
    _draftDebounce = Timer(const Duration(milliseconds: 350), _saveDraft);
  }

  Future<void> _saveDraft() async {
    if (_baseline == null) return;
    try {
      await _draftStore.save(
        CalibrationDraft(
          deviceSerial: _deviceKey,
          baselineCrc32: _baseline!.crc32,
          samples: List.unmodifiable(_samples),
          options: _options,
          fittedCurve: _fit?.curve,
          updatedAt: DateTime.now(),
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _notice = '草稿自动保存失败：${_friendlyError(error)}');
      }
    }
  }

  Future<void> _showSampleEditor({int? index}) async {
    final sample = index == null ? null : _samples[index];
    final measured = TextEditingController(
      text: sample?.measured.toStringAsFixed(3) ?? '',
    );
    final reference = TextEditingController(
      text: sample?.reference.toStringAsFixed(3) ?? '',
    );
    final result = await showModalBottomSheet<CalibrationSample>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          20 + MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              index == null ? '手动添加温点' : '编辑温点',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: measured,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(
                labelText: '设备当前显示温度',
                suffixText: '℃',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reference,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(
                labelText: '参考温度',
                suffixText: '℃',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                final measuredValue = double.tryParse(measured.text.trim());
                final referenceValue = double.tryParse(reference.text.trim());
                if (measuredValue == null || referenceValue == null) return;
                Navigator.pop(
                  sheetContext,
                  CalibrationSample(
                    measured: measuredValue,
                    reference: referenceValue,
                    rawInput: _baseline?.invert(measuredValue),
                    standardDeviation: sample?.standardDeviation ?? 0,
                    frameCount: sample?.frameCount ?? 1,
                  ),
                );
              },
              child: const Text('保存温点'),
            ),
          ],
        ),
      ),
    );
    measured.dispose();
    reference.dispose();
    if (result == null || !mounted) return;
    setState(() {
      if (index == null) {
        _samples.add(result);
      } else {
        _samples[index] = result;
      }
    });
    _dataChanged();
  }

  Future<void> _importCsv() async {
    try {
      final imported = await CalibrationCsvService.pickAndRead();
      if (imported == null || !mounted) return;
      final currentSerial = context.read<AppState>().deviceSerial;
      final serialMismatch =
          imported.deviceSerials.isNotEmpty &&
          currentSerial != null &&
          !imported.deviceSerials.contains(currentSerial);
      final baselineMismatch =
          imported.baselineCrcs.isNotEmpty &&
          _baseline != null &&
          !imported.baselineCrcs.contains(_baseline!.crc32);
      setState(() {
        _samples.addAll(
          imported.samples.map(
            (sample) => sample.rawInput == null
                ? sample.copyWith(rawInput: _baseline?.invert(sample.measured))
                : sample,
          ),
        );
        _notice = serialMismatch
            ? '已导入 ${imported.samples.length} 个温点；CSV 设备 SN 与当前设备不同，请核对后再写入。'
            : baselineMismatch
            ? '已导入 ${imported.samples.length} 个温点；CSV 基线曲线 CRC 与当前设备不同，请核对原始温度列。'
            : '已导入 ${imported.samples.length} 个温点。';
      });
      _dataChanged();
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    }
  }

  Future<void> _exportCsv() async {
    if (_samples.isEmpty) return;
    try {
      final path = await CalibrationCsvService.export(
        samples: _samples,
        deviceSerial: _deviceKey,
        baselineCrc: _baseline?.crc32,
      );
      if (mounted && path != null) BananaToast.show(context, '校准数据已导出');
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    }
  }

  void _updateBreakpoints(String text) {
    final values = <double>[];
    for (final token in text.split(RegExp(r'[,，;；\s]+'))) {
      if (token.isEmpty) continue;
      final value = double.tryParse(token);
      if (value != null) values.add(value);
    }
    values.sort();
    setState(() => _options = _options.copyWith(manualBreakpoints: values));
    _dataChanged();
  }

  void _useAutomaticBreakpoints() {
    final fit = _fit;
    if (fit == null) return;
    final breakpoints = fit.curve.knots
        .skip(1)
        .take(math.max(0, fit.curve.knots.length - 2))
        .map((knot) => knot.raw)
        .toList(growable: false);
    _breakpointController.text = breakpoints
        .map((value) => value.toStringAsFixed(3))
        .join(', ');
    setState(
      () => _options = _options.copyWith(
        manualMode: true,
        manualBreakpoints: breakpoints,
      ),
    );
    _dataChanged();
  }

  void _addBreakpointFromChart(TapDownDetails details, Size size) {
    if (!_options.manual || _samples.length < 2 || size.width <= 50) return;
    final xs = _samples
        .map((sample) => sample.rawInput ?? sample.measured)
        .toList(growable: false);
    var minimum = xs.reduce(math.min);
    var maximum = xs.reduce(math.max);
    final padding = math.max(1.0, (maximum - minimum) * 0.08);
    minimum -= padding;
    maximum += padding;
    const plotLeft = 42.0;
    final plotRight = size.width - 8.0;
    if (details.localPosition.dx < plotLeft ||
        details.localPosition.dx > plotRight) {
      return;
    }
    final ratio =
        ((details.localPosition.dx - plotLeft) / (plotRight - plotLeft)).clamp(
          0.0,
          1.0,
        );
    final value = minimum + (maximum - minimum) * ratio;
    if (value <= xs.reduce(math.min) || value >= xs.reduce(math.max)) return;
    final breakpoints = [..._options.manualBreakpoints];
    if (breakpoints.any((item) => (item - value).abs() < 0.05)) return;
    breakpoints.add((value * 1000).round() / 1000);
    breakpoints.sort();
    _breakpointController.text = breakpoints
        .map((item) => item.toStringAsFixed(3))
        .join(', ');
    setState(
      () => _options = _options.copyWith(manualBreakpoints: breakpoints),
    );
    _dataChanged();
  }

  Future<void> _applyFit() async {
    final fit = _fit;
    if (fit == null || _applying) return;
    final app = context.read<AppState>();
    final validation = fit.curve.validate();
    if (!validation.valid) {
      setState(() => _error = validation.errors.join('；'));
      return;
    }
    final supportsV2 = app.deviceSupportsCalibrationV2;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          supportsV2 ? Icons.ssid_chart_rounded : Icons.warning_amber_rounded,
        ),
        title: Text(
          supportsV2 ? '写入 ${fit.curve.segmentCount} 段校准曲线？' : '旧固件将降级为全局直线',
        ),
        content: Text(
          supportsV2
              ? '曲线会通过 CRC 校验后原子启用并持久化。有效范围 '
                    '${fit.curve.rangeMinimum.toStringAsFixed(1)}℃–${fit.curve.rangeMaximum.toStringAsFixed(1)}℃，'
                    '范围外保持端点修正量。'
              : '当前固件不支持分段协议，将写入最佳稳健直线：'
                    'T = 原始温度 × ${fit.fallbackLinear.gain.toStringAsFixed(6)} '
                    '${_signed(fit.fallbackLinear.offset, digits: 3)}℃。'
                    '升级固件后才能使用 ${fit.curve.segmentCount} 段结果。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(supportsV2 ? '写入并校验' : '降级写入直线'),
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
      final result = await app.applyTemperatureCalibrationCurve(
        fit.curve,
        fallbackLinear: fit.fallbackLinear,
      );
      if (!mounted) return;
      setState(() {
        _baseline = result;
        _notice = result.kind == CalibrationCurveKind.piecewise
            ? '${result.segmentCount} 段校准曲线已写入并通过 CRC 校验。'
            : '已按旧协议写入最佳全局直线。';
      });
      await _saveDraft();
      if (mounted) BananaToast.show(context, '温度校准已保存到设备');
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _resetCalibration() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.restart_alt_rounded),
        title: const Text('恢复默认校准？'),
        content: const Text('设备将恢复恒等校准，现有本地温点草稿会保留。'),
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
    setState(() => _applying = true);
    try {
      final curve = await context
          .read<AppState>()
          .resetTemperatureCalibrationCurve();
      if (mounted) {
        setState(() {
          _baseline = curve;
          _notice = '设备已恢复默认校准；草稿温点仍保留。';
        });
      }
      _scheduleFit(immediate: true);
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('热成像多段温度校准'),
        actions: [
          IconButton(
            tooltip: '重新读取设备校准',
            onPressed: _busy ? null : _refreshCalibration,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 900;
            final preview = _buildPreview(app);
            final workflow = _buildWorkflow(app);
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1280),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                  children: [
                    _buildIntro(),
                    if (_error != null) ...[
                      const SizedBox(height: 10),
                      _Banner(message: _error!, error: true),
                    ],
                    if (_notice != null) ...[
                      const SizedBox(height: 10),
                      _Banner(message: _notice!, error: false),
                    ],
                    const SizedBox(height: 12),
                    if (wide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 360, child: preview),
                          const SizedBox(width: 12),
                          Expanded(child: workflow),
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
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.auto_graph_rounded),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                '普通使用只需输入参考温度并采集。系统会自动判断需要多少段，并用交叉验证限制过拟合；'
                '只有新增分段能改善未参与拟合的数据时才会保留。',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(AppState app) {
    RenderedFrame? rendered;
    if (app.thermalFrame != null) {
      rendered = renderPipeline(
        thermalFrame: app.thermalFrame!,
        srcW: app.thermalWidth,
        srcH: app.thermalHeight,
        params: app.renderParams,
      );
    }
    final liveRoi = app.thermalFrame == null
        ? null
        : centerRoiTrimmedMean(
            app.thermalFrame!,
            width: app.thermalWidth,
            height: app.thermalHeight,
          );
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
                      '中央采样区',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    _ValueChip(value: liveRoi),
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
        _buildDeviceState(app),
      ],
    );
  }

  Widget _buildDeviceState(AppState app) {
    final curve = _baseline;
    return Card(
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
                  '设备当前校准',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                if (_loading)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _ParameterRow(
              label: '协议',
              value: app.deviceSupportsCalibrationV2 ? 'v2 分段原子协议' : '单段兼容协议',
            ),
            const SizedBox(height: 8),
            _ParameterRow(
              label: '有效段数',
              value: curve == null ? '尚未读取' : '${curve.segmentCount}',
            ),
            if (curve?.kind == CalibrationCurveKind.piecewise) ...[
              const SizedBox(height: 8),
              _ParameterRow(
                label: '原始温区',
                value:
                    '${curve!.rangeMinimum.toStringAsFixed(1)}–${curve.rangeMaximum.toStringAsFixed(1)} ℃',
              ),
              const SizedBox(height: 8),
              _ParameterRow(
                label: 'CRC32',
                value:
                    '0x${curve.crc32!.toRadixString(16).padLeft(8, '0').toUpperCase()}',
              ),
            ],
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: curve == null || _busy ? null : _resetCalibration,
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: const Text('恢复默认校准'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWorkflow(AppState app) {
    return Column(
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '1. 录入参考温点',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
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
                    ),
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      onPressed:
                          _sampling ||
                              _applying ||
                              _baseline == null ||
                              app.thermalFrame == null
                          ? null
                          : _capturePoint,
                      icon: _sampling
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.center_focus_strong_rounded),
                      label: Text(
                        _sampling
                            ? '$_sampleProgress / $_calibrationSampleFrameTarget'
                            : '自动采集',
                      ),
                    ),
                  ],
                ),
                if (_sampling) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: _sampleProgress / _calibrationSampleFrameTarget,
                  ),
                ],
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _showSampleEditor(),
                      icon: const Icon(Icons.edit_note_rounded),
                      label: const Text('手动添加'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _importCsv,
                      icon: const Icon(Icons.file_upload_outlined),
                      label: const Text('导入 CSV'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _samples.isEmpty ? null : _exportCsv,
                      icon: const Icon(Icons.file_download_outlined),
                      label: const Text('导出 CSV'),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (_samples.isEmpty)
                  const _EmptyState()
                else
                  SizedBox(
                    height: math.min(420, _samples.length * 82).toDouble(),
                    child: Scrollbar(
                      child: ListView.separated(
                        primary: false,
                        itemCount: _samples.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, i) => _SampleTile(
                          index: i,
                          sample: _samples[i],
                          residual: i < (_fit?.residuals.length ?? 0)
                              ? _fit!.residuals[i]
                              : null,
                          outlier:
                              i < (_fit?.outliers.length ?? 0) &&
                              _fit!.outliers[i],
                          onEdit: _busy
                              ? null
                              : () => _showSampleEditor(index: i),
                          onDelete: _busy
                              ? null
                              : () {
                                  setState(() => _samples.removeAt(i));
                                  _dataChanged();
                                },
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _buildAdvanced(),
        const SizedBox(height: 12),
        _buildResult(),
      ],
    );
  }

  Widget _buildAdvanced() {
    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        leading: const Icon(Icons.tune_rounded),
        title: const Text('高级拟合与手动分段'),
        subtitle: Text(
          _options.manual
              ? '手动断点，系数仍自动稳健拟合'
              : '自动分段 · 灵敏度 ${_options.sensitivity.round()}',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('手动指定断点'),
            subtitle: const Text('只指定原始温度断点，连续曲线和各段系数仍自动计算'),
            value: _options.manual,
            onChanged: (value) {
              setState(() => _options = _options.copyWith(manualMode: value));
              _dataChanged();
            },
          ),
          if (_options.manual)
            TextField(
              controller: _breakpointController,
              onChanged: _updateBreakpoints,
              decoration: const InputDecoration(
                labelText: '原始温度断点',
                hintText: '例如 0, 50, 100',
                suffixText: '℃',
                border: OutlineInputBorder(),
              ),
            )
          else ...[
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _fit == null ? null : _useAutomaticBreakpoints,
                icon: const Icon(Icons.call_split_rounded),
                label: const Text('从自动结果转为手动'),
              ),
            ),
            _LabeledSlider(
              label: '分段灵敏度',
              valueText: _options.sensitivity.round().toString(),
              value: _options.sensitivity,
              min: 0,
              max: 100,
              divisions: 20,
              onChanged: (value) => setState(
                () => _options = _options.copyWith(sensitivity: value),
              ),
              onChangeEnd: (_) => _dataChanged(),
            ),
            _LabeledSlider(
              label: '最大分段数',
              valueText: '${_options.maximumSegments}',
              value: _options.maximumSegments.toDouble(),
              min: 1,
              max: 128,
              divisions: 127,
              onChanged: (value) => setState(
                () => _options = _options.copyWith(
                  maximumSegments: value.round(),
                ),
              ),
              onChangeEnd: (_) => _dataChanged(),
            ),
          ],
          _LabeledSlider(
            label: '每段最少独立温点',
            valueText: '${_options.minimumPointsPerSegment}',
            value: _options.minimumPointsPerSegment.toDouble(),
            min: 3,
            max: 8,
            divisions: 5,
            onChanged: (value) => setState(
              () => _options = _options.copyWith(
                minimumPointsPerSegment: value.round(),
              ),
            ),
            onChangeEnd: (_) => _dataChanged(),
          ),
          _LabeledSlider(
            label: '最小分段温跨',
            valueText: '${_options.minimumSegmentSpan.toStringAsFixed(1)}℃',
            value: _options.minimumSegmentSpan.clamp(0.5, 20),
            min: 0.5,
            max: 20,
            divisions: 39,
            onChanged: (value) => setState(
              () => _options = _options.copyWith(minimumSegmentSpan: value),
            ),
            onChangeEnd: (_) => _dataChanged(),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('稳健拟合'),
            subtitle: const Text('降低孤立异常点的权重，但仍在结果中标出'),
            value: _options.robust,
            onChanged: (value) {
              setState(() => _options = _options.copyWith(robust: value));
              _dataChanged();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildResult() {
    final fit = _fit;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_graph_rounded, size: 20),
                const SizedBox(width: 8),
                const Text(
                  '2. 自动计算并写入',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
                const Spacer(),
                if (_fitting)
                  TextButton.icon(
                    onPressed: _cancelFit,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('取消计算'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (_samples.length < 2)
              const Text('至少录入两个不同温度的参考点后开始计算。')
            else if (_fitting)
              const LinearProgressIndicator()
            else if (fit == null)
              const Text('暂无可用拟合结果。')
            else ...[
              SizedBox(
                height: 250,
                child: LayoutBuilder(
                  builder: (context, constraints) => GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: _options.manual
                        ? (details) => _addBreakpointFromChart(
                            details,
                            constraints.biggest,
                          )
                        : null,
                    child: CustomPaint(
                      painter: _CalibrationChartPainter(
                        curve: fit.curve,
                        samples: _samples,
                        outliers: fit.outliers,
                        colorScheme: Theme.of(context).colorScheme,
                      ),
                    ),
                  ),
                ),
              ),
              if (_options.manual)
                Text(
                  '点按图表可添加断点；删除或精确修改请使用高级设置中的断点输入框。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _MetricChip(
                    label: '自动选择',
                    value: '${fit.curve.segmentCount} 段',
                    good: true,
                  ),
                  _MetricChip(
                    label: '训练 RMSE',
                    value: '${fit.rootMeanSquareError.toStringAsFixed(3)}℃',
                    good: fit.rootMeanSquareError <= 0.5,
                  ),
                  _MetricChip(
                    label: '验证 RMSE',
                    value: '${fit.validationRmse.toStringAsFixed(3)}℃',
                    good: fit.validationRmse <= 0.5,
                  ),
                  _MetricChip(
                    label: '最大误差',
                    value: '${fit.maximumAbsoluteError.toStringAsFixed(3)}℃',
                    good: fit.maximumAbsoluteError <= 1,
                  ),
                  _MetricChip(
                    label: 'R²',
                    value: fit.rSquared.toStringAsFixed(4),
                    good: fit.rSquared >= 0.99,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _ModelSelectionSummary(
                scores: fit.modelScores,
                selected: fit.curve.segmentCount,
              ),
              if (fit.warnings.isNotEmpty) ...[
                const SizedBox(height: 10),
                for (final warning in fit.warnings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '• $warning',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.tertiary,
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _applying || !fit.isWithinDeviceLimits
                    ? null
                    : _applyFit,
                icon: _applying
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.save_rounded),
                label: Text(_applying ? '正在传输并校验…' : '写入并保存到设备'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

double? centerRoiTrimmedMean(
  Float32List frame, {
  int width = 32,
  int height = 24,
}) {
  if (width < 8 || height < 8 || frame.length < width * height) return null;
  final startX = (width - 8) ~/ 2;
  final startY = (height - 8) ~/ 2;
  final values = <double>[];
  for (var y = startY; y < startY + 8; y++) {
    for (var x = startX; x < startX + 8; x++) {
      final value = frame[y * width + x];
      if (value.isFinite && value >= -100 && value <= 500) values.add(value);
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

String _signed(double value, {int digits = 2}) =>
    '${value >= 0 ? '+' : '−'} ${value.abs().toStringAsFixed(digits)}';

class _ValueChip extends StatelessWidget {
  const _ValueChip({required this.value});
  final double? value;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      value == null ? '--.- ℃' : '${value!.toStringAsFixed(2)} ℃',
      style: const TextStyle(fontWeight: FontWeight.w700),
    ),
  );
}

class _ParameterRow extends StatelessWidget {
  const _ParameterRow({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          label,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      SelectableText(
        value,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ],
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(12),
    ),
    child: const Text('还没有参考点。每次自动采集会对中央区域连续采集 24 帧。'),
  );
}

class _SampleTile extends StatelessWidget {
  const _SampleTile({
    required this.index,
    required this.sample,
    required this.residual,
    required this.outlier,
    required this.onEdit,
    required this.onDelete,
  });
  final int index;
  final CalibrationSample sample;
  final double? residual;
  final bool outlier;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: outlier
          ? scheme.errorContainer.withValues(alpha: 0.45)
          : scheme.surfaceContainerHighest.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onEdit,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              CircleAvatar(
                radius: 15,
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '设备 ${sample.measured.toStringAsFixed(2)}℃  →  参考 ${sample.reference.toStringAsFixed(2)}℃',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '${sample.frameCount > 1 ? 'σ ${sample.standardDeviation.toStringAsFixed(3)}℃ · ${sample.frameCount} 帧' : '手动录入'}'
                      '${residual == null ? '' : ' · 残差 ${_signed(residual!, digits: 3)}℃'}'
                      '${outlier ? ' · 异常点已降权' : ''}',
                      style: TextStyle(
                        fontSize: 12,
                        color: outlier ? scheme.error : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '删除',
                onPressed: onDelete,
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ),
        ),
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
    final color = good ? Colors.green : Theme.of(context).colorScheme.tertiary;
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

class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.label,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onChangeEnd,
  });
  final String label;
  final String valueText;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        children: [
          Expanded(child: Text(label)),
          Text(valueText, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
      Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        onChanged: onChanged,
        onChangeEnd: onChangeEnd,
      ),
    ],
  );
}

class _ModelSelectionSummary extends StatelessWidget {
  const _ModelSelectionSummary({required this.scores, required this.selected});
  final List<CalibrationModelScore> scores;
  final int selected;
  @override
  Widget build(BuildContext context) {
    if (scores.isEmpty) return const SizedBox.shrink();
    final finite = scores
        .where((score) => score.validationRmse.isFinite)
        .toList();
    final maximum = finite.isEmpty
        ? 1.0
        : finite.map((score) => score.validationRmse).reduce(math.max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('段数与验证误差', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        for (final score in scores.take(12))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                SizedBox(
                  width: 38,
                  child: Text(
                    '${score.segments} 段',
                    style: TextStyle(
                      fontWeight: score.segments == selected
                          ? FontWeight.w700
                          : null,
                    ),
                  ),
                ),
                Expanded(
                  child: LinearProgressIndicator(
                    value: score.validationRmse.isFinite
                        ? (score.validationRmse / maximum).clamp(0, 1)
                        : 1,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 66,
                  child: Text(
                    score.validationRmse.isFinite
                        ? '${score.validationRmse.toStringAsFixed(3)}℃'
                        : '不可用',
                  ),
                ),
              ],
            ),
          ),
        if (scores.length > 12)
          Text(
            '另有 ${scores.length - 12} 个候选模型',
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    );
  }
}

class _CalibrationChartPainter extends CustomPainter {
  const _CalibrationChartPainter({
    required this.curve,
    required this.samples,
    required this.outliers,
    required this.colorScheme,
  });
  final CalibrationCurve curve;
  final List<CalibrationSample> samples;
  final List<bool> outliers;
  final ColorScheme colorScheme;
  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;
    final xs = samples
        .map((sample) => sample.rawInput ?? sample.measured)
        .toList();
    final ys = samples.map((sample) => sample.reference).toList();
    var minX = xs.reduce(math.min);
    var maxX = xs.reduce(math.max);
    var minY = ys.reduce(math.min);
    var maxY = ys.reduce(math.max);
    final padX = math.max(1.0, (maxX - minX) * 0.08);
    final padY = math.max(1.0, (maxY - minY) * 0.08);
    minX -= padX;
    maxX += padX;
    minY -= padY;
    maxY += padY;
    const left = 42.0;
    const top = 10.0;
    const right = 8.0;
    const bottom = 26.0;
    final plot = Rect.fromLTRB(
      left,
      top,
      size.width - right,
      size.height - bottom,
    );
    double px(double x) => plot.left + (x - minX) / (maxX - minX) * plot.width;
    double py(double y) =>
        plot.bottom - (y - minY) / (maxY - minY) * plot.height;
    final grid = Paint()
      ..color = colorScheme.outlineVariant.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = plot.top + plot.height * i / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
    }
    canvas.drawRect(
      plot,
      Paint()
        ..color = colorScheme.outline
        ..style = PaintingStyle.stroke,
    );
    final path = Path();
    for (var i = 0; i <= 160; i++) {
      final x = minX + (maxX - minX) * i / 160;
      final point = Offset(px(x), py(curve.correct(x)));
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = colorScheme.primary
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke,
    );
    for (var i = 0; i < samples.length; i++) {
      canvas.drawCircle(
        Offset(px(xs[i]), py(ys[i])),
        4.5,
        Paint()
          ..color = i < outliers.length && outliers[i]
              ? colorScheme.error
              : colorScheme.secondary,
      );
    }
    for (final knot
        in curve.knots.skip(1).take(math.max(0, curve.knots.length - 2))) {
      canvas.drawLine(
        Offset(px(knot.raw), plot.top),
        Offset(px(knot.raw), plot.bottom),
        Paint()
          ..color = colorScheme.tertiary.withValues(alpha: 0.55)
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CalibrationChartPainter oldDelegate) =>
      oldDelegate.curve != curve ||
      oldDelegate.samples != samples ||
      oldDelegate.outliers != outliers;
}

class _Banner extends StatelessWidget {
  const _Banner({required this.message, required this.error});
  final String message;
  final bool error;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: error ? scheme.errorContainer : scheme.secondaryContainer,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              error ? Icons.error_outline_rounded : Icons.info_outline_rounded,
              color: error
                  ? scheme.onErrorContainer
                  : scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: error
                      ? scheme.onErrorContainer
                      : scheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
