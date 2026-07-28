/// 实时温度记录导出弹窗。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../temperature/temperature_export_service.dart';
import '../temperature/temperature_recorder.dart';

Future<void> showTemperatureExportDialog(
  BuildContext context, {
  required bool singlePointMode,
  String? initialDirectory,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _TemperatureExportDialog(
      singlePointMode: singlePointMode,
      initialDirectory: initialDirectory,
    ),
  );
}

class _TemperatureExportDialog extends StatefulWidget {
  final bool singlePointMode;
  final String? initialDirectory;

  const _TemperatureExportDialog({
    required this.singlePointMode,
    required this.initialDirectory,
  });

  @override
  State<_TemperatureExportDialog> createState() =>
      _TemperatureExportDialogState();
}

class _TemperatureExportDialogState extends State<_TemperatureExportDialog> {
  final GlobalKey _previewKey = GlobalKey();
  late List<TemperatureSample> _samples;
  bool _csv = true;
  bool _png = true;
  bool _json = false;
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _samples = List<TemperatureSample>.from(
      TemperatureRecorder.instance.records,
    );
  }

  Future<Uint8List> _renderPreviewPng() async {
    await WidgetsBinding.instance.endOfFrame;
    final boundary =
        _previewKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) throw StateError('趋势图尚未完成渲染');
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('无法生成趋势图图片');
      return data.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  Future<void> _export() async {
    if (_busy || _samples.isEmpty || !(_csv || _png || _json)) return;
    setState(() {
      _busy = true;
      _status = '正在准备导出…';
    });
    final base = TemperatureExportService.timestampedBaseName();
    final exported = <String>[];
    try {
      Uint8List? pngBytes;
      if (_png) pngBytes = await _renderPreviewPng();
      if (_csv) {
        final path = await TemperatureExportService.saveBytes(
          bytes: TemperatureExportService.buildCsv(_samples),
          fileName: '$base.csv',
          extension: 'csv',
          initialDirectory: widget.initialDirectory,
        );
        if (path != null) exported.add(path);
      }
      if (_json) {
        final path = await TemperatureExportService.saveBytes(
          bytes: TemperatureExportService.buildJson(_samples),
          fileName: '$base.json',
          extension: 'json',
          initialDirectory: widget.initialDirectory,
        );
        if (path != null) exported.add(path);
      }
      if (_png && pngBytes != null) {
        final path = await TemperatureExportService.savePng(
          bytes: pngBytes,
          fileName: '$base.png',
          initialDirectory: widget.initialDirectory,
        );
        if (path != null) exported.add(path);
      }
      if (!mounted) return;
      setState(() {
        _status = exported.isEmpty
            ? '没有导出文件（保存操作已取消）'
            : '已导出 ${exported.length} 个文件\n${exported.join('\n')}';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '导出失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearRecords() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空温度记录？'),
        content: const Text('已记录的最高、最低、平均及测温点数据都会被清空，此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    TemperatureRecorder.instance.clearRecords();
    setState(() {
      _samples = [];
      _status = '记录已清空，将从下一帧重新开始记录。';
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final previewHeight = size.width < 520 ? 150.0 : 230.0;
    final first = _samples.isEmpty ? null : _samples.first.timestamp;
    final last = _samples.isEmpty ? null : _samples.last.timestamp;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
      title: Row(
        children: [
          const Icon(Icons.ios_share_rounded, size: 22),
          const SizedBox(width: 10),
          const Expanded(child: Text('导出温度记录')),
          IconButton(
            tooltip: '关闭',
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 760,
          maxHeight: size.height * 0.76,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  children: [
                    Text('记录数：${_samples.length}'),
                    Text(
                      '记录频率：${TemperatureRecorder.instance.sampleIntervalLabel}',
                    ),
                    if (first != null && last != null)
                      Text('时段：${_shortTime(first)} – ${_shortTime(last)}'),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: previewHeight,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: RepaintBoundary(
                      key: _previewKey,
                      child: SizedBox(
                        width: 900,
                        height: 500,
                        child: _TemperatureExportPreview(
                          samples: _samples,
                          singlePointMode: widget.singlePointMode,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '选择导出格式（可多选）',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              _ExportOption(
                value: _csv,
                icon: Icons.table_chart_rounded,
                title: 'CSV 原始数据',
                subtitle: '适合 Excel、Python 和后续统计分析，包含所有测温点。',
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _csv = value),
              ),
              _ExportOption(
                value: _png,
                icon: Icons.image_rounded,
                title: 'PNG 趋势图',
                subtitle: '把最高、最低、平均和当前测温模式的趋势渲染成图片。',
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _png = value),
              ),
              _ExportOption(
                value: _json,
                icon: Icons.data_object_rounded,
                title: 'JSON 结构化数据',
                subtitle: '保留时间戳、设备序列号、坐标及每个测温点，便于系统集成。',
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _json = value),
              ),
              if (_status != null) ...[
                const SizedBox(height: 8),
                SelectableText(
                  _status!,
                  style: TextStyle(
                    fontSize: 12,
                    color: _status!.startsWith('导出失败')
                        ? scheme.error
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: (_busy || _samples.isEmpty) ? null : _clearRecords,
          icon: const Icon(Icons.delete_sweep_rounded, size: 18),
          label: const Text('清空记录'),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          onPressed: (_busy || _samples.isEmpty || !(_csv || _png || _json))
              ? null
              : _export,
          icon: _busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download_rounded, size: 18),
          label: Text(_busy ? '导出中…' : '开始导出'),
        ),
      ],
    );
  }

  static String _shortTime(DateTime value) {
    final t = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}

class _ExportOption extends StatelessWidget {
  final bool value;
  final IconData icon;
  final String title;
  final String subtitle;
  final ValueChanged<bool>? onChanged;

  const _ExportOption({
    required this.value,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      value: value,
      onChanged: onChanged == null ? null : (next) => onChanged!(next ?? false),
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      secondary: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
    );
  }
}

class _TemperatureExportPreview extends StatelessWidget {
  final List<TemperatureSample> samples;
  final bool singlePointMode;

  const _TemperatureExportPreview({
    required this.samples,
    required this.singlePointMode,
  });

  @override
  Widget build(BuildContext context) {
    // 图片覆盖整段会话。超长记录等距抽样，避免数万点同时绘制导致导出卡顿。
    final chartSamples = samples.length <= 900
        ? samples
        : List<TemperatureSample>.generate(900, (index) {
            final sourceIndex = (index * (samples.length - 1) / 899).round();
            return samples[sourceIndex];
          });
    List<FlSpot> spots(double? Function(TemperatureSample sample) valueOf) => [
      for (var i = 0; i < chartSamples.length; i++)
        if (valueOf(chartSamples[i]) case final double value)
          FlSpot(i.toDouble(), value),
    ];
    final selectedLabel = singlePointMode ? '单点' : '多点均值';
    final selectedSpots = spots(
      (sample) =>
          singlePointMode ? sample.singleTemperature : sample.multiPointAverage,
    );
    final lines = <LineChartBarData>[
      _line(spots((sample) => sample.maximum), const Color(0xFFFF5252)),
      _line(spots((sample) => sample.minimum), const Color(0xFF42A5F5)),
      _line(spots((sample) => sample.average), const Color(0xFF66BB6A)),
      if (selectedSpots.isNotEmpty)
        _line(selectedSpots, const Color(0xFFAB47BC), width: 3),
    ];
    return ColoredBox(
      color: const Color(0xFF111418),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'BananaThermal 温度趋势记录',
              style: TextStyle(
                color: Colors.white,
                fontFamily: 'SmileySans',
                fontSize: 28,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _previewLegend(const Color(0xFFFF5252), '最高'),
                _previewLegend(const Color(0xFF42A5F5), '最低'),
                _previewLegend(const Color(0xFF66BB6A), '平均'),
                if (selectedSpots.isNotEmpty)
                  _previewLegend(const Color(0xFFAB47BC), selectedLabel),
                const Spacer(),
                Text(
                  '${samples.length} 条记录',
                  style: const TextStyle(color: Colors.white60, fontSize: 16),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: chartSamples.isEmpty
                  ? const Center(
                      child: Text(
                        '暂无温度记录',
                        style: TextStyle(color: Colors.white54, fontSize: 22),
                      ),
                    )
                  : LineChart(
                      LineChartData(
                        lineTouchData: const LineTouchData(enabled: false),
                        gridData: FlGridData(
                          show: true,
                          drawVerticalLine: false,
                          getDrawingHorizontalLine: (_) => FlLine(
                            color: Colors.white.withValues(alpha: 0.12),
                            strokeWidth: 1,
                          ),
                        ),
                        borderData: FlBorderData(
                          show: true,
                          border: Border.all(color: Colors.white24),
                        ),
                        titlesData: FlTitlesData(
                          topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          bottomTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          leftTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 54,
                              getTitlesWidget: (value, _) => Text(
                                '${value.toStringAsFixed(1)}°',
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ),
                        ),
                        lineBarsData: lines,
                      ),
                      duration: Duration.zero,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  static LineChartBarData _line(
    List<FlSpot> spots,
    Color color, {
    double width = 2.2,
  }) {
    return LineChartBarData(
      spots: spots,
      color: color,
      barWidth: width,
      isCurved: true,
      dotData: const FlDotData(show: false),
    );
  }

  static Widget _previewLegend(Color color, String label) {
    return Padding(
      padding: const EdgeInsets.only(right: 20),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ],
      ),
    );
  }
}
