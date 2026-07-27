/// 视差校正测试 Tab: 可视化双光对齐全过程, 支持手动调整和实时预览.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../fusion/fusion.dart';
import '../fusion/parallax_aligner.dart';
import '../render/render_params.dart';
import '../render/render_pipeline.dart';
import 'widgets/rgb_image_view.dart';

// 预览分辨率倍率 (热像 32×24 的输出倍率)
const int _kPreviewScale = 5; // → 160×120 px
const int _kTW = 32, _kTH = 24;
const int _kPW = _kTW * _kPreviewScale, _kPH = _kTH * _kPreviewScale;

class ParallaxTab extends StatefulWidget {
  const ParallaxTab({super.key});

  @override
  State<ParallaxTab> createState() => _ParallaxTabState();
}

class _ParallaxTabState extends State<ParallaxTab> {
  bool _edgeMode = false; // 切换到边缘对比模式

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final p = app.renderParams;
    final scheme = Theme.of(context).colorScheme;

    final tf = app.thermalFrame;
    final vr = app.visibleRgb888;
    final hasData = tf != null && vr != null &&
        app.visibleWidth > 0 && app.visibleHeight > 0;

    // ----------- 渲染三联图 -----------
    final (Uint8List? imgThermal, Uint8List? imgVisible, Uint8List? imgFused) =
        hasData
            ? _buildTriple(tf, vr, app.visibleWidth, app.visibleHeight, p)
            : (null, null, null);

    final (Uint8List? edgeT, Uint8List? edgeV) =
        (_edgeMode && hasData)
            ? _buildEdgeMaps(tf, vr, app.visibleWidth, app.visibleHeight, p)
            : (null, null);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 三联预览区 ──
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      Text('预览',
                          style: Theme.of(context).textTheme.titleSmall),
                      const Spacer(),
                      _EdgeModeToggle(
                          value: _edgeMode,
                          onChanged: (v) => setState(() => _edgeMode = v)),
                    ],
                  ),
                ),
                if (!hasData)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Text(
                      '暂无数据 — 请先连接设备并开启双光推流',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        // 三列等宽自适应
                        final colW = (constraints.maxWidth - 32) / 3;
                        final colH = colW * _kPH / _kPW;
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _PreviewPanel(
                              label: '热像',
                              rgb: _edgeMode ? edgeT : imgThermal,
                              width: _kPW,
                              height: _kPH,
                              colW: colW,
                              colH: colH,
                            ),
                            const SizedBox(width: 8),
                            _PreviewPanel(
                              label: '可见光',
                              rgb: _edgeMode ? edgeV : imgVisible,
                              width: _kPW,
                              height: _kPH,
                              colW: colW,
                              colH: colH,
                            ),
                            const SizedBox(width: 8),
                            _PreviewPanel(
                              label: _edgeMode ? '边缘叠加' : '融合效果',
                              rgb: _edgeMode
                                  ? _blendEdges(edgeT, edgeV, _kPW, _kPH)
                                  : imgFused,
                              width: _kPW,
                              height: _kPH,
                              colW: colW,
                              colH: colH,
                            ),
                          ],
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 10),

          // ── 参数控制卡 ──
          Card(
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('视差参数',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 10),

                  // 自动对齐开关
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('自动对齐',
                                style: TextStyle(fontSize: 13)),
                            Text('每 10 s 自动计算并更新偏移',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                      Switch(
                        value: p.parallaxEnabled,
                        onChanged: (v) => app.updateRenderParams(
                            p.copyWith(parallaxEnabled: v)),
                      ),
                    ],
                  ),

                  const SizedBox(height: 8),
                  const Divider(height: 1),
                  const SizedBox(height: 8),

                  // X 偏移滑杆
                  _ParallaxSlider(
                    label: 'X 偏移',
                    value: p.parallaxDx,
                    onChanged: (v) =>
                        app.updateRenderParams(p.copyWith(parallaxDx: v)),
                  ),
                  const SizedBox(height: 4),

                  // Y 偏移滑杆
                  _ParallaxSlider(
                    label: 'Y 偏移',
                    value: p.parallaxDy,
                    onChanged: (v) =>
                        app.updateRenderParams(p.copyWith(parallaxDy: v)),
                  ),

                  const SizedBox(height: 12),

                  // 操作按钮行
                  Row(
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: hasData
                            ? () => app.triggerParallaxNow()
                            : null,
                        icon: const Icon(
                            Icons.center_focus_strong_rounded,
                            size: 16),
                        label: const Text('立即计算'),
                      ),
                      const SizedBox(width: 8),
                      if (p.parallaxDx != 0 || p.parallaxDy != 0)
                        OutlinedButton(
                          onPressed: () => app.updateRenderParams(
                              p.copyWith(parallaxDx: 0.0, parallaxDy: 0.0)),
                          child: const Text('重置偏移'),
                        ),
                      const Spacer(),
                      _ConfidenceBadge(result: app.lastParallaxResult),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ── 当前偏移状态卡 ──
          _OffsetStateCard(params: p, scheme: scheme),
        ],
      ),
    );
  }

  /// 渲染三张预览图: 热像 / 可见光 (偏移版) / 融合.
  static (Uint8List, Uint8List, Uint8List) _buildTriple(
      Float32List tf,
      Uint8List vr,
      int vw,
      int vh,
      RenderParams p) {
    // 1. 热像着色 (简化版: 不做双边滤波, 加快响应)
    final thermalParams = p.copyWith(
      upsampleScale: _kPreviewScale,
      bilateralEnabled: false,
      fusion: const FusionParams(mode: FusionMode.off),
    );
    final thermalFrame =
        renderPipeline(thermalFrame: tf, srcW: _kTW, srcH: _kTH, params: thermalParams);
    final thermalRgb = thermalFrame.rgb;

    // 2. 可见光 (重采样到 _kPW×_kPH, 无偏移)
    final visNoOffset = _sampleVis(vr, vw, vh, parallaxDx: 0, parallaxDy: 0);

    // 3. 融合 (当前偏移)
    final fusedRgb = fuse(
      thermalRgb: thermalRgb,
      tw: _kPW,
      th: _kPH,
      visibleRgb: vr,
      vw: vw,
      vh: vh,
      params: p.fusion.mode == FusionMode.off
          ? const FusionParams(mode: FusionMode.blend, alpha: 0.5)
          : p.fusion,
      parallaxDx: p.parallaxDx * _kPreviewScale,
      parallaxDy: p.parallaxDy * _kPreviewScale,
    );

    return (thermalRgb, visNoOffset, fusedRgb);
  }

  /// 计算热像和可见光的 Sobel 边缘 (灰度 → 伪彩着色).
  static (Uint8List, Uint8List) _buildEdgeMaps(
      Float32List tf, Uint8List vr, int vw, int vh, RenderParams p) {
    // 热像边缘 (在 _kPW×_kPH 空间)
    final tGray = _thermalToGrayPreview(tf);
    final tEdge = _sobelPreview(tGray, _kPW, _kPH);
    final tEdgeRgb = _edgeToOrangeRgb(tEdge, _kPW, _kPH);

    // 可见光边缘 (无偏移, 在 _kPW×_kPH 空间)
    final vGray = _visibleToGrayPreview(vr, vw, vh, 0, 0);
    final vEdge = _sobelPreview(vGray, _kPW, _kPH);
    final vEdgeRgb = _edgeToCyanRgb(vEdge, _kPW, _kPH);

    return (tEdgeRgb, vEdgeRgb);
  }

  /// 热像 + 可见光边缘叠加 (橙 + 青 = 绿: 对齐区域).
  static Uint8List? _blendEdges(Uint8List? eT, Uint8List? eV, int w, int h) {
    if (eT == null || eV == null) return null;
    final out = Uint8List(w * h * 3);
    final n = w * h;
    for (int i = 0; i < n; i++) {
      final j = i * 3;
      final tR = eT[j], tG = eT[j + 1]; //, tB = eT[j + 2]; // orange: R+G
      final vR = eV[j], vG = eV[j + 1], vB = eV[j + 2]; // cyan: G+B
      // 叠加: 热像贡献红/橙, 可见光贡献青
      out[j] = (tR + vR).clamp(0, 255);
      out[j + 1] = (tG + vG).clamp(0, 255);
      out[j + 2] = vB;
    }
    return out;
  }

  // ── 内部辅助 ────────────────────────────────────────────────────────────

  static Uint8List _sampleVis(Uint8List vr, int vw, int vh,
      {double parallaxDx = 0, double parallaxDy = 0}) {
    final out = Uint8List(_kPW * _kPH * 3);
    final scaleX = vw / _kPW;
    final scaleY = vh / _kPH;
    for (int y = 0; y < _kPH; y++) {
      for (int x = 0; x < _kPW; x++) {
        final sx = ((x - parallaxDx) * scaleX).clamp(0.0, vw - 1.0);
        final sy = ((y - parallaxDy) * scaleY).clamp(0.0, vh - 1.0);
        final ix = sx.floor();
        final iy = sy.floor();
        final fx = sx - ix;
        final fy = sy - iy;
        final ix1 = (ix + 1).clamp(0, vw - 1);
        final iy1 = (iy + 1).clamp(0, vh - 1);
        final w00 = (1 - fx) * (1 - fy);
        final w10 = fx * (1 - fy);
        final w01 = (1 - fx) * fy;
        final w11 = fx * fy;
        final j = (y * _kPW + x) * 3;
        for (int c = 0; c < 3; c++) {
          final v = vr[(iy * vw + ix) * 3 + c] * w00 +
              vr[(iy * vw + ix1) * 3 + c] * w10 +
              vr[(iy1 * vw + ix) * 3 + c] * w01 +
              vr[(iy1 * vw + ix1) * 3 + c] * w11;
          out[j + c] = v.round().clamp(0, 255);
        }
      }
    }
    return out;
  }

  static Float32List _thermalToGrayPreview(Float32List tf) {
    // 热像上采样到 _kPW×_kPH → 灰度 Float32
    double mn = double.infinity, mx = -double.infinity;
    for (final v in tf) {
      if (!v.isFinite) continue;
      if (v < mn) mn = v;
      if (v > mx) mx = v;
    }
    final span = (mx - mn) < 1e-6 ? 1.0 : (mx - mn);
    final gray = Float32List(_kPW * _kPH);
    final scaleX = _kTW / _kPW;
    final scaleY = _kTH / _kPH;
    for (int y = 0; y < _kPH; y++) {
      for (int x = 0; x < _kPW; x++) {
        final sx = (x * scaleX).clamp(0.0, _kTW - 1.0);
        final sy = (y * scaleY).clamp(0.0, _kTH - 1.0);
        final ix = sx.floor();
        final iy = sy.floor();
        final fx = sx - ix;
        final fy = sy - iy;
        final ix1 = (ix + 1).clamp(0, _kTW - 1);
        final iy1 = (iy + 1).clamp(0, _kTH - 1);
        final v = tf[iy * _kTW + ix] * (1 - fx) * (1 - fy) +
            tf[iy * _kTW + ix1] * fx * (1 - fy) +
            tf[iy1 * _kTW + ix] * (1 - fx) * fy +
            tf[iy1 * _kTW + ix1] * fx * fy;
        gray[y * _kPW + x] = ((v - mn) / span).clamp(0.0, 1.0) * 255.0;
      }
    }
    return gray;
  }

  static Float32List _visibleToGrayPreview(
      Uint8List vr, int vw, int vh, double dx, double dy) {
    final gray = Float32List(_kPW * _kPH);
    final scaleX = vw / _kPW;
    final scaleY = vh / _kPH;
    for (int y = 0; y < _kPH; y++) {
      for (int x = 0; x < _kPW; x++) {
        final sx = ((x - dx) * scaleX).clamp(0.0, vw - 1.0);
        final sy = ((y - dy) * scaleY).clamp(0.0, vh - 1.0);
        final ix = sx.floor();
        final iy = sy.floor();
        final fx = sx - ix;
        final fy = sy - iy;
        final ix1 = (ix + 1).clamp(0, vw - 1);
        final iy1 = (iy + 1).clamp(0, vh - 1);
        double v = 0;
        for (int c = 0; c < 3; c++) {
          final w = [0.299, 0.587, 0.114][c];
          v += (vr[(iy * vw + ix) * 3 + c] * (1 - fx) * (1 - fy) +
                  vr[(iy * vw + ix1) * 3 + c] * fx * (1 - fy) +
                  vr[(iy1 * vw + ix) * 3 + c] * (1 - fx) * fy +
                  vr[(iy1 * vw + ix1) * 3 + c] * fx * fy) *
              w;
        }
        gray[y * _kPW + x] = v;
      }
    }
    return gray;
  }

  static Float32List _sobelPreview(Float32List gray, int w, int h) {
    final mag = Float32List(w * h);
    for (int y = 1; y < h - 1; y++) {
      for (int x = 1; x < w - 1; x++) {
        final i = y * w + x;
        final gx = -gray[i - w - 1] + gray[i - w + 1] -
            2 * gray[i - 1] + 2 * gray[i + 1] -
            gray[i + w - 1] + gray[i + w + 1];
        final gy = -gray[i - w - 1] - 2 * gray[i - w] - gray[i - w + 1] +
            gray[i + w - 1] + 2 * gray[i + w] + gray[i + w + 1];
        mag[i] = gx.abs() + gy.abs();
      }
    }
    // 归一化
    double mx = 0;
    for (final v in mag) {
      if (v > mx) mx = v;
    }
    if (mx > 1e-6) {
      for (int i = 0; i < mag.length; i++) mag[i] /= mx;
    }
    return mag;
  }

  static Uint8List _edgeToOrangeRgb(Float32List mag, int w, int h) {
    final out = Uint8List(w * h * 3);
    for (int i = 0; i < w * h; i++) {
      final v = (mag[i] * 255).round().clamp(0, 255);
      out[i * 3] = v;         // R: 强
      out[i * 3 + 1] = (v * 0.6).round(); // G: 中 → 橙
      out[i * 3 + 2] = 0;    // B: 无
    }
    return out;
  }

  static Uint8List _edgeToCyanRgb(Float32List mag, int w, int h) {
    final out = Uint8List(w * h * 3);
    for (int i = 0; i < w * h; i++) {
      final v = (mag[i] * 255).round().clamp(0, 255);
      out[i * 3] = 0;     // R: 无
      out[i * 3 + 1] = v; // G: 强
      out[i * 3 + 2] = v; // B: 强 → 青
    }
    return out;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 子 Widget
// ─────────────────────────────────────────────────────────────────────────────

class _PreviewPanel extends StatelessWidget {
  final String label;
  final Uint8List? rgb;
  final int width;
  final int height;
  final double colW;
  final double colH;

  const _PreviewPanel({
    required this.label,
    required this.rgb,
    required this.width,
    required this.height,
    required this.colW,
    required this.colH,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: colW,
              height: colH,
              child: rgb == null
                  ? ColoredBox(color: scheme.surfaceContainerHigh)
                  : RgbImageView(
                      rgb: rgb,
                      width: width,
                      height: height,
                      filterQuality: FilterQuality.none,
                    ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _EdgeModeToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const _EdgeModeToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: value
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.blur_on_rounded,
                size: 14,
                color: value ? scheme.onPrimaryContainer : scheme.onSurface),
            const SizedBox(width: 4),
            Text(
              '边缘模式',
              style: TextStyle(
                fontSize: 12,
                color:
                    value ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ParallaxSlider extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  const _ParallaxSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const max = 8.0;
    return Row(
      children: [
        SizedBox(
          width: 52,
          child: Text(label,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(-max, max),
            min: -max,
            max: max,
            divisions: 160, // 0.1 步长
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 60,
          child: Text(
            '${value >= 0 ? '+' : ''}${value.toStringAsFixed(1)} px',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

class _ConfidenceBadge extends StatelessWidget {
  final ParallaxResult? result;
  const _ConfidenceBadge({required this.result});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (result == null) {
      return Text('尚未计算',
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant));
    }
    final conf = result!.confidence;
    final ok = conf >= kMinConfidence;
    final color = ok
        ? Color.lerp(Colors.orange, Colors.green, math.min(1.0, (conf - kMinConfidence) / 0.5))!
        : scheme.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '置信度',
          style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
        ),
        Text(
          conf.toStringAsFixed(2),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
            color: color,
          ),
        ),
        if (!ok)
          Text(
            '特征不足',
            style: TextStyle(fontSize: 10, color: scheme.error),
          ),
      ],
    );
  }
}

class _OffsetStateCard extends StatelessWidget {
  final RenderParams params;
  final ColorScheme scheme;
  const _OffsetStateCard({required this.params, required this.scheme});

  @override
  Widget build(BuildContext context) {
    final p = params;
    final hasOffset = p.parallaxDx != 0 || p.parallaxDy != 0;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前偏移状态',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            _StateRow(
              icon: Icons.swap_horiz_rounded,
              label: 'X (水平)',
              value: p.parallaxDx,
              scheme: scheme,
            ),
            const SizedBox(height: 4),
            _StateRow(
              icon: Icons.swap_vert_rounded,
              label: 'Y (垂直)',
              value: p.parallaxDy,
              scheme: scheme,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  p.parallaxEnabled
                      ? Icons.autorenew_rounded
                      : Icons.pause_circle_outline_rounded,
                  size: 14,
                  color: p.parallaxEnabled
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  p.parallaxEnabled
                      ? '自动对齐已开启 (每 10 s 重算)'
                      : '自动对齐已关闭 (手动偏移固定)',
                  style: TextStyle(
                    fontSize: 11,
                    color: p.parallaxEnabled
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                ),
                if (hasOffset) ...[
                  const Spacer(),
                  Icon(Icons.check_circle_outline_rounded,
                      size: 14, color: Colors.green),
                  const SizedBox(width: 4),
                  Text('已校正',
                      style:
                          const TextStyle(fontSize: 11, color: Colors.green)),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StateRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final double value;
  final ColorScheme scheme;
  const _StateRow(
      {required this.icon,
      required this.label,
      required this.value,
      required this.scheme});

  @override
  Widget build(BuildContext context) {
    final isZero = value == 0;
    return Row(
      children: [
        Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: 8),
        SizedBox(
          width: 64,
          child: Text(label,
              style: TextStyle(
                  fontSize: 12, color: scheme.onSurfaceVariant)),
        ),
        Text(
          '${value >= 0 ? '+' : ''}${value.toStringAsFixed(2)} 热像素',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            fontWeight: isZero ? FontWeight.normal : FontWeight.w600,
            color: isZero ? scheme.onSurfaceVariant : scheme.primary,
          ),
        ),
      ],
    );
  }
}
