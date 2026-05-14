/// 实时投屏 Tab - 现代扁平卡片布局.
library;

import 'dart:typed_data';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../fusion/fusion.dart';
import '../main.dart' show appWideBreakpoint, appConsoleExpanded;
import '../protocol/frame_parser.dart';
import '../render/render_params.dart';
import '../render/render_pipeline.dart';
import 'widgets/rgb_image_view.dart';
import 'widgets/thermal_canvas.dart';

class RealtimeTab extends StatelessWidget {
  const RealtimeTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: appWideBreakpoint,
      builder: (context, breakpoint, _) => LayoutBuilder(
      builder: (context, c) {
        // 宽屏: 顶部主区(左热像主画面 + 右侧栏[可见光/温度/趋势/控制]), 底部串口控制台 (全宽)
        // 窄屏: 纵向堆叠
        final wide = c.maxWidth > breakpoint;
        if (wide) {
          return Column(
            children: const [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 1, child: _ThermalCard()),
                    SizedBox(width: 12),
                    Expanded(flex: 1, child: _RightAside()),
                  ],
                ),
              ),
              SizedBox(height: 12),
              _CollapsibleConsole(expandedHeight: 180),
            ],
          );
        }
        return const _NarrowLayout();
      },
    ),
    );
  }
}

/// 窄屏纵向堆叠. 用 SingleChildScrollView 保证小窗口可滚动到底.
class _NarrowLayout extends StatelessWidget {
  const _NarrowLayout();
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: const [
          _KpiRow(),
          SizedBox(height: 12),
          SizedBox(height: 360, child: _ThermalCard()),
          SizedBox(height: 12),
          SizedBox(height: 160, child: _ChartCard()),
          SizedBox(height: 12),
          _ControlsCard(),
          SizedBox(height: 12),
          _CollapsibleConsole(expandedHeight: 200),
        ],
      ),
    );
  }
}

class _KpiRow extends StatelessWidget {
  const _KpiRow();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Row(
      children: [
        Expanded(
          child: _KpiTile(
            label: '最高温度',
            value: app.tMax,
            color: const Color(0xFFFF5252),
            icon: Icons.local_fire_department_rounded,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _KpiTile(
            label: '最低温度',
            value: app.tMin,
            color: const Color(0xFF42A5F5),
            icon: Icons.ac_unit_rounded,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _KpiTile(
            label: '平均温度',
            value: app.tAvg,
            color: const Color(0xFF66BB6A),
            icon: Icons.analytics_rounded,
          ),
        ),
      ],
    );
  }
}

class _KpiTile extends StatelessWidget {
  final String label;
  final double value;
  final Color color;
  final IconData icon;
  const _KpiTile({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    )),
                const SizedBox(height: 2),
                Text(
                  '${value.toStringAsFixed(1)} °C',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'SmileySans',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ThermalCard extends StatelessWidget {
  const _ThermalCard();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    RenderedFrame? frame;
    if (app.thermalFrame != null) {
      frame = renderPipeline(
        thermalFrame: app.thermalFrame!,
        srcW: 32,
        srcH: 24,
        params: app.renderParams,
        visibleRgb: app.visibleRgb888,
        visibleW: app.visibleWidth,
        visibleH: app.visibleHeight,
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.thermostat_rounded, size: 18),
                const SizedBox(width: 8),
                const Text('主画面',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
                const Spacer(),
                const _ThermalStreamSwitch(),
                const SizedBox(width: 14),
                const _VisibleStreamSwitch(),
                const SizedBox(width: 14),
                const _VisibleFloatingLauncher(),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ThermalCanvas(
                frame: frame,
                showCursorTemp: app.renderParams.showCursorTemp,
                placeholder: '等待热像数据…',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThermalStreamSwitch extends StatelessWidget {
  const _ThermalStreamSwitch();
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final enabled = app.status == ConnectionStatus.connected;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('热成像',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            )),
        const SizedBox(width: 6),
        Transform.scale(
          scale: 0.85,
          child: Switch(
            value: app.thermalStreamEnabled,
            onChanged: enabled ? app.setThermalStream : null,
          ),
        ),
      ],
    );
  }
}

class _VisibleStreamSwitch extends StatelessWidget {
  const _VisibleStreamSwitch();
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final enabled = app.status == ConnectionStatus.connected;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('可见光',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            )),
        const SizedBox(width: 6),
        Transform.scale(
          scale: 0.85,
          child: Switch(
            value: app.visibleStreamEnabled,
            onChanged: enabled ? app.setVisibleStream : null,
          ),
        ),
      ],
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    List<FlSpot> spotsOf(List<double> arr) =>
        [for (var i = 0; i < arr.length; i++) FlSpot(i.toDouble(), arr[i])];

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.show_chart_rounded, size: 18),
                const SizedBox(width: 8),
                const Text('温度趋势',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14)),
                const Spacer(),
                _LegendDot(color: const Color(0xFFFF5252), label: '最高'),
                const SizedBox(width: 8),
                _LegendDot(color: const Color(0xFF42A5F5), label: '最低'),
                const SizedBox(width: 8),
                _LegendDot(color: const Color(0xFF66BB6A), label: '平均'),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: app.historyMax.isEmpty
                  ? Center(
                      child: Text(
                        '暂无数据',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                          fontSize: 12,
                        ),
                      ),
                    )
                  : LineChart(LineChartData(
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipColor: (_) =>
                              scheme.surfaceContainerHighest
                                  .withValues(alpha: 0.92),
                          tooltipRoundedRadius: 8,
                          tooltipPadding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          getTooltipItems: (touchedSpots) {
                            const labels = ['最高', '最低', '平均'];
                            return [
                              for (final s in touchedSpots)
                                LineTooltipItem(
                                  '${labels[s.barIndex.clamp(0, 2)]} ${s.y.toStringAsFixed(2)} °C',
                                  TextStyle(
                                    color: s.bar.color ?? scheme.onSurface,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                            ];
                          },
                        ),
                      ),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        getDrawingHorizontalLine: (_) => FlLine(
                          color:
                              scheme.outlineVariant.withValues(alpha: 0.15),
                          strokeWidth: 1,
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      titlesData: const FlTitlesData(show: false),
                      lineBarsData: [
                        LineChartBarData(
                          spots: spotsOf(app.historyMax),
                          color: const Color(0xFFFF5252),
                          barWidth: 2,
                          isCurved: true,
                          dotData: const FlDotData(show: false),
                        ),
                        LineChartBarData(
                          spots: spotsOf(app.historyMin),
                          color: const Color(0xFF42A5F5),
                          barWidth: 2,
                          isCurved: true,
                          dotData: const FlDotData(show: false),
                        ),
                        LineChartBarData(
                          spots: spotsOf(app.historyAvg),
                          color: const Color(0xFF66BB6A),
                          barWidth: 2,
                          isCurved: true,
                          dotData: const FlDotData(show: false),
                        ),
                      ],
                    )),
            ),
          ],
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}

// =========================================================================
// 右侧栏: 可见光 + 控制面板
// =========================================================================

class _RightAside extends StatelessWidget {
  const _RightAside();

  @override
  Widget build(BuildContext context) {
    // 右侧栏: 温度 KPI / 温度趋势 / 控制面板 (可滚动)
    // 推流开关与可见光浮窗按钮已移至主画面卡标题栏.
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: const [
          _KpiRow(),
          SizedBox(height: 12),
          SizedBox(height: 140, child: _ChartCard()),
          SizedBox(height: 12),
          _ControlsCard(),
        ],
      ),
    );
  }
}

class _VisibleCard extends StatelessWidget {
  const _VisibleCard();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;

    Uint8List? rgb;
    int w = 0, h = 0;
    if (app.visibleRgb888 != null) {
      rgb = app.visibleRgb888;
      w = app.visibleWidth;
      h = app.visibleHeight;
    }
    final enabled = app.status == ConnectionStatus.connected;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.photo_camera_rounded, size: 18),
                const SizedBox(width: 8),
                const Text('可见光',
                    style:
                        TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                const Spacer(),
                Text('推流',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    )),
                const SizedBox(width: 6),
                Transform.scale(
                  scale: 0.85,
                  child: Switch(
                    value: app.visibleStreamEnabled,
                    onChanged: enabled ? app.setVisibleStream : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: scheme.outlineVariant.withValues(alpha: 0.15),
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: rgb == null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.camera_alt_outlined,
                                size: 40,
                                color: scheme.onSurfaceVariant
                                    .withValues(alpha: 0.4),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '可见光待开启',
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        )
                      : RgbImageView(
                          rgb: rgb,
                          width: w,
                          height: h,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.medium,
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlsCard extends StatelessWidget {
  const _ControlsCard();

  @override
  Widget build(BuildContext context) {
    // 现代化布局: 常用项 (颜色 / 曲线 / 融合模式) 一行下拉直显;
    // 进阶项 (上采样, 滤波, 卡尔曼, 融合参数) 折叠收纳, 默认收起.
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: const [
          Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: _QuickPanel(),
          ),
          Divider(height: 1),
          _CollapseSection(
            icon: Icons.zoom_in_rounded,
            title: '上采样',
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: _UpsamplePicker(),
            ),
          ),
          _CollapseSection(
            icon: Icons.blur_on_rounded,
            title: '滤波',
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: _FilterSection(),
            ),
          ),
          _CollapseSection(
            icon: Icons.tune_rounded,
            title: '融合参数',
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: _FusionSliders(),
            ),
          ),
        ],
      ),
    );
  }
}

/// 常驻面板: 颜色映射 / 映射曲线 / 融合模式 一行三下拉, 等宽自适应.
class _QuickPanel extends StatelessWidget {
  const _QuickPanel();

  @override
  Widget build(BuildContext context) {
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: _ColormapDropdown()),
        SizedBox(width: 8),
        Expanded(child: _CurveDropdown()),
        SizedBox(width: 8),
        Expanded(child: _FusionModeDropdown()),
      ],
    );
  }
}

class _CollapseSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;
  const _CollapseSection(
      {required this.icon, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Theme(
      // 去掉 ExpansionTile 默认的上下分割线噪声
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        leading: Icon(icon, size: 18),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: EdgeInsets.zero,
        children: [child],
      ),
    );
  }
}

class _UpsamplePicker extends StatelessWidget {
  const _UpsamplePicker();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final p = app.renderParams;
    const scales = [1, 2, 4, 8, 16];
    return Row(
      children: [
        Expanded(
          child: _LabeledDropdown<int>(
            label: '倍率',
            value: p.upsampleScale,
            items: [
              for (final s in scales)
                DropdownMenuItem(value: s, child: Text('${s}x')),
            ],
            onChanged: (v) =>
                app.updateRenderParams(p.copyWith(upsampleScale: v)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _LabeledDropdown<UpsampleMethod>(
            label: '方法',
            value: p.upsampleMethod,
            items: const [
              DropdownMenuItem(
                  value: UpsampleMethod.nearest, child: Text('最近')),
              DropdownMenuItem(
                  value: UpsampleMethod.bilinear, child: Text('双线性')),
              DropdownMenuItem(
                  value: UpsampleMethod.bicubic, child: Text('双三次')),
            ],
            onChanged: (v) =>
                app.updateRenderParams(p.copyWith(upsampleMethod: v)),
          ),
        ),
      ],
    );
  }
}

/// 扭平风格下拉: 紧凑, 无边框, 圆角填充, 小 label 在上方.
/// 在 Row+Expanded 中能自适应列宽; isExpanded 使当前选项填满可用宽度.
class _LabeledDropdown<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T> onChanged;
  const _LabeledDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              height: 1.0,
              color: scheme.onSurfaceVariant,
              letterSpacing: 0.3,
            ),
          ),
          DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              isDense: true,
              isExpanded: true,
              // 弹出菜单圆角 + 限高滚动, 避免长列表占满屏幕.
              borderRadius: BorderRadius.circular(14),
              menuMaxHeight: 280,
              icon: Icon(Icons.expand_more_rounded,
                  size: 18, color: scheme.onSurfaceVariant),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
              items: items,
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 滤波合并区: 三个开关(双边 / 卡尔曼·温度 / 卡尔曼·像素) 同行;
/// 双边启用时 σ空间 + σ亮度 同行许.
class _FilterSection extends StatelessWidget {
  const _FilterSection();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final p = app.renderParams;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _SwitchTile(
                label: '双边滤波',
                value: p.bilateralEnabled,
                onChanged: (v) => app
                    .updateRenderParams(p.copyWith(bilateralEnabled: v)),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _SwitchTile(
                label: '卡尔曼·温度',
                value: app.kalmanScalarEnabled,
                onChanged: app.setKalmanScalar,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _SwitchTile(
                label: '卡尔曼·像素',
                value: app.kalmanPixelEnabled,
                onChanged: app.setKalmanPixel,
              ),
            ),
          ],
        ),
        if (p.bilateralEnabled) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _SliderRow(
                  label: 'σ空间',
                  value: p.bilateralSigmaSpatial,
                  min: 0.5,
                  max: 4.0,
                  onChanged: (v) => app.updateRenderParams(
                      p.copyWith(bilateralSigmaSpatial: v)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SliderRow(
                  label: 'σ亮度',
                  value: p.bilateralSigmaIntensity,
                  min: 0.1,
                  max: 5.0,
                  onChanged: (v) => app.updateRenderParams(
                      p.copyWith(bilateralSigmaIntensity: v)),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// 扭平风格 "小卡片 + 开关" 控件, 用于 滤波 区多开关同行.
class _SwitchTile extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _SwitchTile({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: value
          ? scheme.primary.withValues(alpha: 0.18)
          : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight:
                        value ? FontWeight.w700 : FontWeight.w500,
                    color: value
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Transform.scale(
                scale: 0.7,
                child: Switch(
                  value: value,
                  onChanged: onChanged,
                  materialTapTargetSize:
                      MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final IconData icon;
  final String text;
  const _SectionTitle({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16),
        const SizedBox(width: 8),
        Text(text,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
            )),
      ],
    );
  }
}

class _ColormapDropdown extends StatelessWidget {
  const _ColormapDropdown();

  /// 色盘 key (英文, 与 colormap 查表保持一致) -> 中文显示名.
  static const _names = <String, String>{
    'jet': '喷射',
    'hot': '热力',
    'inferno': '炽焰',
    'magma': '岩浆',
    'plasma': '等离子',
    'viridis': '翠绿',
    'cividis': '柠黄',
    'turbo': '涡轮',
    'gray': '灰阶',
    'cool': '冷色',
    'rainbow': '彩虹',
  };

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return _LabeledDropdown<String>(
      label: '颜色映射',
      value: app.renderParams.colormapName,
      items: [
        for (final e in _names.entries)
          DropdownMenuItem(value: e.key, child: Text(e.value)),
      ],
      onChanged: (v) => app.updateRenderParams(
          app.renderParams.copyWith(colormapName: v)),
    );
  }
}

class _CurveDropdown extends StatelessWidget {
  const _CurveDropdown();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return _LabeledDropdown<String>(
      label: '映射曲线',
      value: app.renderParams.mappingCurve,
      items: const [
        DropdownMenuItem(value: 'linear', child: Text('线性')),
        DropdownMenuItem(value: 'nonlinear', child: Text('S 曲线')),
      ],
      onChanged: (v) => app.updateRenderParams(
          app.renderParams.copyWith(mappingCurve: v)),
    );
  }
}

// _KalmanRow 已合并到 _FilterSection, 不再单独使用.

class _FusionModeDropdown extends StatelessWidget {
  const _FusionModeDropdown();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final fp = app.renderParams.fusion;
    return _LabeledDropdown<FusionMode>(
      label: '可见光融合',
      value: fp.mode,
      items: const [
        DropdownMenuItem(value: FusionMode.off, child: Text('关闭')),
        DropdownMenuItem(value: FusionMode.blend, child: Text('混合')),
        DropdownMenuItem(value: FusionMode.edge, child: Text('边缘叠加')),
      ],
      onChanged: (mode) {
        app.updateRenderParams(app.renderParams.copyWith(
          fusion: FusionParams(
            mode: mode,
            gamma: fp.gamma,
            alpha: fp.alpha,
            edgeStrength: fp.edgeStrength,
            edgeThresh: fp.edgeThresh,
            edgeWidth: fp.edgeWidth,
            edgeColor: fp.edgeColor,
          ),
        ));
      },
    );
  }
}

class _FusionSliders extends StatelessWidget {
  const _FusionSliders();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final p = app.renderParams.fusion;
    void set({double? alpha, double? gamma, double? es, double? et, double? ew}) {
      app.updateRenderParams(app.renderParams.copyWith(
        fusion: FusionParams(
          mode: p.mode,
          alpha: alpha ?? p.alpha,
          gamma: gamma ?? p.gamma,
          edgeStrength: es ?? p.edgeStrength,
          edgeThresh: et ?? p.edgeThresh,
          edgeWidth: ew ?? p.edgeWidth,
          edgeColor: p.edgeColor,
        ),
      ));
    }

    if (p.mode == FusionMode.blend) {
      return Column(
        children: [
          _SliderRow(label: 'Alpha', value: p.alpha, onChanged: (v) => set(alpha: v)),
          _SliderRow(
              label: 'Gamma',
              value: p.gamma,
              min: 0.2,
              max: 3.0,
              onChanged: (v) => set(gamma: v)),
        ],
      );
    } else if (p.mode == FusionMode.edge) {
      return Column(
        children: [
          _SliderRow(
              label: '强度',
              value: p.edgeStrength,
              onChanged: (v) => set(es: v)),
          _SliderRow(
              label: '阈值',
              value: p.edgeThresh,
              max: 0.5,
              onChanged: (v) => set(et: v)),
          _SliderRow(
              label: '粗细',
              value: p.edgeWidth.clamp(1.0, 6.0),
              min: 1,
              max: 6,
              divisions: 20,
              valueLabel: '${p.edgeWidth.toStringAsFixed(2)} px',
              onChanged: (v) => set(ew: v)),
        ],
      );
    }
    return const SizedBox.shrink();
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String? valueLabel;
  final ValueChanged<double> onChanged;
  const _SliderRow({
    required this.label,
    required this.value,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.valueLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
              width: 50,
              child: Text(label,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ))),
          Expanded(
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              valueLabel ?? value.toStringAsFixed(2),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.18)
          : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

// =========================================================================
// 控制台
// =========================================================================

class _ConsoleCard extends StatefulWidget {
  const _ConsoleCard({this.onCollapse});
  final VoidCallback? onCollapse;

  @override
  State<_ConsoleCard> createState() => _ConsoleCardState();
}

class _ConsoleCardState extends State<_ConsoleCard> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Color _logColor(String level, ColorScheme scheme) {
    switch (level) {
      case 'tx':
        return const Color(0xFFFFCA28);
      case 'rx':
        return const Color(0xFF81C784);
      case 'warn':
        return const Color(0xFFFFB74D);
      case 'err':
        return const Color(0xFFEF5350);
      default:
        return scheme.onSurfaceVariant;
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.terminal_rounded, size: 18),
                const SizedBox(width: 8),
                const Text('串口控制台',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14)),
                const Spacer(),
                Text('${app.logs.length} 条',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    )),
                const SizedBox(width: 8),
                _MiniIcon(
                  icon: Icons.delete_sweep_rounded,
                  onTap: app.clearLogs,
                  tooltip: '清空',
                ),
                if (widget.onCollapse != null) ...[
                  const SizedBox(width: 4),
                  _MiniIcon(
                    icon: Icons.keyboard_arrow_down_rounded,
                    onTap: widget.onCollapse!,
                    tooltip: '收起控制台',
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListView.builder(
                  controller: _scroll,
                  itemCount: app.logs.length,
                  itemBuilder: (_, i) {
                    final e = app.logs[i];
                    final ts =
                        '${e.time.hour.toString().padLeft(2, '0')}:${e.time.minute.toString().padLeft(2, '0')}:${e.time.second.toString().padLeft(2, '0')}';
                    return Text(
                      '[$ts] ${e.text}',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        height: 1.45,
                        color: _logColor(e.level, scheme),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    decoration: const InputDecoration(
                      hintText: '输入命令 (如 GetSysInfo) 回车发送',
                    ),
                    onSubmitted: (v) {
                      if (v.trim().isEmpty) return;
                      app.sendCommand(v);
                      _ctrl.clear();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () {
                    if (_ctrl.text.trim().isEmpty) return;
                    app.sendCommand(_ctrl.text);
                    _ctrl.clear();
                  },
                  icon: const Icon(Icons.send_rounded, size: 16),
                  label: const Text('发送'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  const _MiniIcon({required this.icon, required this.onTap, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget w = Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 15, color: scheme.onSurfaceVariant),
        ),
      ),
    );
    if (tooltip != null) w = Tooltip(message: tooltip!, child: w);
    return w;
  }
}

// =========================================================================
// 可见光浮窗: 工具栏按钮 + 可拖动的悬浮迷你窗
// =========================================================================

class _VisibleFloatingLauncher extends StatefulWidget {
  const _VisibleFloatingLauncher();
  @override
  State<_VisibleFloatingLauncher> createState() =>
      _VisibleFloatingLauncherState();
}

class _VisibleFloatingLauncherState extends State<_VisibleFloatingLauncher> {
  OverlayEntry? _entry;
  // 浮窗左上角偏移与尺寸 (跨开关持久化)
  Offset _pos = const Offset(80, 80);
  Size _size = const Size(360, 280);

  bool get _open => _entry != null;

  void _toggle() {
    if (_open) {
      _close();
    } else {
      _show();
    }
  }

  void _show() {
    _entry = OverlayEntry(
      builder: (ctx) => _VisibleFloatingPanel(
        initialOffset: _pos,
        initialSize: _size,
        onMove: (o) => _pos = o,
        onResize: (s) => _size = s,
        onClose: _close,
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_entry!);
    setState(() {});
  }

  void _close() {
    _entry?.remove();
    _entry = null;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: _toggle,
      icon: Icon(
        _open ? Icons.close_rounded : Icons.photo_camera_rounded,
        size: 16,
      ),
      label: Text(_open ? '关闭可见光' : '可见光'),
    );
  }
}

class _VisibleFloatingPanel extends StatefulWidget {
  final Offset initialOffset;
  final Size initialSize;
  final ValueChanged<Offset> onMove;
  final ValueChanged<Size> onResize;
  final VoidCallback onClose;
  const _VisibleFloatingPanel({
    required this.initialOffset,
    required this.initialSize,
    required this.onMove,
    required this.onResize,
    required this.onClose,
  });

  @override
  State<_VisibleFloatingPanel> createState() => _VisibleFloatingPanelState();
}

class _VisibleFloatingPanelState extends State<_VisibleFloatingPanel> {
  late Offset _pos = widget.initialOffset;
  late Size _size = widget.initialSize;

  void _drag(DragUpdateDetails d) {
    setState(() {
      _pos = _pos + d.delta;
      widget.onMove(_pos);
    });
  }

  void _resize(DragUpdateDetails d) {
    setState(() {
      _size = Size(
        (_size.width + d.delta.dx).clamp(240.0, 1200.0),
        (_size.height + d.delta.dy).clamp(180.0, 900.0),
      );
      widget.onResize(_size);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final app = context.watch<AppState>();
    final rgb = app.visibleRgb888;

    return Positioned(
      left: _pos.dx,
      top: _pos.dy,
      child: Material(
        color: Colors.transparent,
        elevation: 18,
        shadowColor: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: _size.width,
          height: _size.height,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
          child: Column(
            children: [
              // 标题栏: 可拖动
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: _drag,
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(14),
                      topRight: Radius.circular(14),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.photo_camera_rounded, size: 16),
                      const SizedBox(width: 6),
                      const Text('可见光',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          )),
                      const Spacer(),
                      InkWell(
                        onTap: widget.onClose,
                        borderRadius: BorderRadius.circular(6),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.close_rounded, size: 16),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 画面区
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(14),
                    bottomRight: Radius.circular(14),
                  ),
                  child: Stack(
                    children: [
                      Container(
                        color: scheme.surface,
                        child: rgb == null
                            ? Center(
                                child: Text(
                                  '可见光待开启',
                                  style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                    fontSize: 12,
                                  ),
                                ),
                              )
                            : RgbImageView(
                                rgb: rgb,
                                width: app.visibleWidth,
                                height: app.visibleHeight,
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.medium,
                              ),
                      ),
                      // 右下角缩放手柄
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanUpdate: _resize,
                          child: MouseRegion(
                            cursor:
                                SystemMouseCursors.resizeDownRight,
                            child: Container(
                              width: 18,
                              height: 18,
                              alignment: Alignment.bottomRight,
                              padding: const EdgeInsets.all(2),
                              child: Icon(
                                Icons.south_east_rounded,
                                size: 12,
                                color: scheme.onSurfaceVariant
                                    .withValues(alpha: 0.7),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 折叠式串口控制台: 默认显示为一条底部灰色横条, 悬停高亮提示可点击,
/// 点击后展开为完整控制台, 再次点击右上角箭头收起. 展开/收起均带动画.
class _CollapsibleConsole extends StatelessWidget {
  const _CollapsibleConsole({required this.expandedHeight});
  final double expandedHeight;

  static const Duration _kAnim = Duration(milliseconds: 260);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: appConsoleExpanded,
      builder: (context, expanded, _) {
        return AnimatedSize(
          duration: _kAnim,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: double.infinity,
            height: expanded ? expandedHeight : 32,
            child: AnimatedSwitcher(
              duration: _kAnim,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.08),
                    end: Offset.zero,
                  ).animate(anim),
                  child: child,
                ),
              ),
              child: expanded
                  ? _ExpandedConsoleShell(
                      key: const ValueKey('expanded'),
                      onCollapse: () => appConsoleExpanded.value = false,
                    )
                  : _CollapsedConsoleBar(
                      key: const ValueKey('collapsed'),
                      onExpand: () => appConsoleExpanded.value = true,
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _CollapsedConsoleBar extends StatefulWidget {
  const _CollapsedConsoleBar({super.key, required this.onExpand});
  final VoidCallback onExpand;

  @override
  State<_CollapsedConsoleBar> createState() => _CollapsedConsoleBarState();
}

class _CollapsedConsoleBarState extends State<_CollapsedConsoleBar> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final app = context.watch<AppState>();
    final base = scheme.surfaceContainerHigh;
    final hi = scheme.primary.withValues(alpha: 0.18);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: _hover ? hi : base,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _hover
                ? scheme.primary.withValues(alpha: 0.5)
                : scheme.outlineVariant.withValues(alpha: 0.4),
            width: 1,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: widget.onExpand,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Icon(
                    Icons.terminal_rounded,
                    size: 16,
                    color: _hover ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '串口控制台',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _hover
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${app.logs.length} 条',
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const Spacer(),
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 180),
                    opacity: _hover ? 1.0 : 0.55,
                    child: Row(
                      children: [
                        Text(
                          _hover ? '点击展开' : '点击展开控制台',
                          style: TextStyle(
                            fontSize: 11,
                            color: _hover
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.keyboard_arrow_up_rounded,
                          size: 16,
                          color:
                              _hover ? scheme.primary : scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 展开态: 复用 _ConsoleCard, header 末尾额外插一个收起按钮.
class _ExpandedConsoleShell extends StatelessWidget {
  const _ExpandedConsoleShell({super.key, required this.onCollapse});
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    return _ConsoleCard(onCollapse: onCollapse);
  }
}



