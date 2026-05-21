/// 视差详细调整 Dialog: 沉浸式 ~85% 屏占, 三联画 (可见光 / 热成像 / 融合)
/// + Sobel 自动对齐按钮 + 双轴细调滑块.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../fusion/fusion.dart';
import '../../render/render_params.dart';
import '../../render/render_pipeline.dart';
import 'rgb_image_view.dart';

class ParallaxAdjustDialog extends StatelessWidget {
  const ParallaxAdjustDialog({super.key});

  /// 在主画面上方弹出. 屏宽/高各留 ~15% 边距.
  static Future<void> show(BuildContext context) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭',
      barrierColor: Colors.black.withValues(alpha: 0.65),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, anim, secAnim) => const ParallaxAdjustDialog(),
      transitionBuilder: (ctx, anim, secAnim, child) {
        final curved =
            CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween(begin: 0.96, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final w = mq.size.width * 0.85;
    final h = mq.size.height * 0.85;
    return Center(
      child: SizedBox(
        width: w,
        height: h,
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          elevation: 24,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: const _ParallaxDialogBody(),
        ),
      ),
    );
  }
}

class _ParallaxDialogBody extends StatefulWidget {
  const _ParallaxDialogBody();
  @override
  State<_ParallaxDialogBody> createState() => _ParallaxDialogBodyState();
}

class _ParallaxDialogBodyState extends State<_ParallaxDialogBody> {
  bool _autoBusy = false;
  String? _autoHint;

  Future<void> _runAuto(AppState app) async {
    final tf = app.thermalFrame;
    final vis = app.visibleRgb888;
    final vw = app.visibleWidth, vh = app.visibleHeight;
    if (tf == null || vis == null || vw == 0 || vh == 0) {
      setState(() => _autoHint = '需要同时有热成像与可见光画面');
      return;
    }
    setState(() {
      _autoBusy = true;
      _autoHint = null;
    });
    // 当前帧很小 (32x24 热像 + 2x 工作分辨率), 直接同步算, 不开 isolate.
    final off = estimateParallax(
      thermalFrame: tf,
      srcW: 32,
      srcH: 24,
      visibleRgb: vis,
      vw: vw,
      vh: vh,
    );
    if (!mounted) return;
    final fp = app.renderParams.fusion;
    app.updateRenderParams(
      app.renderParams.copyWith(
        fusion: fp.copyWith(parallaxX: off.x, parallaxY: off.y),
      ),
    );
    setState(() {
      _autoBusy = false;
      _autoHint =
          '已应用: dx=${off.x.toStringAsFixed(2)} px, dy=${off.y.toStringAsFixed(2)} px';
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final fp = app.renderParams.fusion;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶栏
        Container(
          padding: const EdgeInsets.fromLTRB(20, 14, 8, 14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            border: Border(
                bottom:
                    BorderSide(color: scheme.outlineVariant, width: 0.6)),
          ),
          child: Row(
            children: [
              const _EyeOverlapIcon(size: 22),
              const SizedBox(width: 10),
              const Text('视差详细调整',
                  style:
                      TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              const SizedBox(width: 12),
              Text(
                '双光融合热成像 · 热像相对可见光偏移 (单位: 热像源像素 32×24)',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
                tooltip: '关闭',
              ),
            ],
          ),
        ),
        // 三联画
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: const [
                Expanded(
                  child:
                      _PreviewTile(kind: _PreviewKind.visible, title: '可见光'),
                ),
                SizedBox(width: 10),
                Expanded(
                  child:
                      _PreviewTile(kind: _PreviewKind.thermal, title: '热成像'),
                ),
                SizedBox(width: 10),
                Expanded(
                  child:
                      _PreviewTile(kind: _PreviewKind.fused, title: '融合预览'),
                ),
              ],
            ),
          ),
        ),
        // 自动调整 + 滑块
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _autoBusy ? null : () => _runAuto(app),
                    icon: _autoBusy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_fix_high_rounded),
                    label: const Text('自动调整 (Sobel 边缘对齐)'),
                  ),
                  const SizedBox(width: 12),
                  if (_autoHint != null)
                    Flexible(
                      child: Text(
                        _autoHint!,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () {
                      app.updateRenderParams(app.renderParams.copyWith(
                        fusion: fp.copyWith(parallaxX: 0, parallaxY: 0),
                      ));
                    },
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('归零'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              _ParallaxSliderRow(
                label: '水平 dx',
                value: fp.parallaxX,
                onChanged: (v) => app.updateRenderParams(
                  app.renderParams.copyWith(
                    fusion: fp.copyWith(parallaxX: v),
                  ),
                ),
              ),
              _ParallaxSliderRow(
                label: '垂直 dy',
                value: fp.parallaxY,
                onChanged: (v) => app.updateRenderParams(
                  app.renderParams.copyWith(
                    fusion: fp.copyWith(parallaxY: v),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

enum _PreviewKind { visible, thermal, fused }

class _PreviewTile extends StatelessWidget {
  final _PreviewKind kind;
  final String title;
  const _PreviewTile({required this.kind, required this.title});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;

    Uint8List? rgb;
    int w = 0, h = 0;

    if (kind == _PreviewKind.visible) {
      rgb = app.visibleRgb888;
      w = app.visibleWidth;
      h = app.visibleHeight;
    } else if (app.thermalFrame != null) {
      // 热像 / 融合都走 renderPipeline. 融合预览强制 blend 模式 (alpha=0.5)
      // 便于直观观察对齐效果, 不依赖用户当前 fusion 模式选择.
      RenderParams p = app.renderParams;
      if (kind == _PreviewKind.thermal) {
        p = p.copyWith(fusion: p.fusion.copyWith(mode: FusionMode.off));
      } else {
        // fused
        final cur = p.fusion;
        p = p.copyWith(
          fusion: cur.mode == FusionMode.off
              ? cur.copyWith(mode: FusionMode.blend, alpha: 0.5)
              : cur,
        );
      }
      final frame = renderPipeline(
        thermalFrame: app.thermalFrame!,
        srcW: 32,
        srcH: 24,
        params: p,
        visibleRgb:
            kind == _PreviewKind.thermal ? null : app.visibleRgb888,
        visibleW:
            kind == _PreviewKind.thermal ? 0 : app.visibleWidth,
        visibleH:
            kind == _PreviewKind.thermal ? 0 : app.visibleHeight,
      );
      rgb = frame.rgb;
      w = frame.width;
      h = frame.height;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
              ),
            ),
            Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13)),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.outlineVariant, width: 0.6),
            ),
            clipBehavior: Clip.antiAlias,
            child: rgb == null || w == 0 || h == 0
                ? Center(
                    child: Text(
                      '等待画面...',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  )
                : RgbImageView(
                    rgb: rgb,
                    width: w,
                    height: h,
                    fit: BoxFit.contain,
                  ),
          ),
        ),
      ],
    );
  }
}

class _ParallaxSliderRow extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  const _ParallaxSliderRow({
    required this.label,
    required this.value,
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
            width: 64,
            child: Text(label,
                style: TextStyle(
                    fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(-15.0, 15.0),
              min: -15,
              max: 15,
              divisions: 300, // 0.1 px 步长
              label: '${value.toStringAsFixed(1)} px',
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(
              '${value.toStringAsFixed(2)} px',
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

/// 双眼重叠图标 — 视差功能视觉标识. 左右两个 outline 眼睛微错位 +
/// 中心略叠加, 用 Stack 实现.
class EyeOverlapIcon extends StatelessWidget {
  final double size;
  final Color? color;
  const EyeOverlapIcon({super.key, this.size = 18, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurface;
    final double off = size * 0.18;
    return SizedBox(
      width: size + off * 2,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: Icon(Icons.remove_red_eye_outlined,
                size: size, color: c.withValues(alpha: 0.55)),
          ),
          Positioned(
            left: off * 2,
            top: 0,
            child: Icon(Icons.remove_red_eye_outlined,
                size: size, color: c),
          ),
        ],
      ),
    );
  }
}

// 私有别名: 顶栏内复用同款图标.
class _EyeOverlapIcon extends StatelessWidget {
  final double size;
  const _EyeOverlapIcon({this.size = 18});
  @override
  Widget build(BuildContext context) => EyeOverlapIcon(size: size);
}
