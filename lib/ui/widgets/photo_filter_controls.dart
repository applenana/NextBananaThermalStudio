import 'dart:io';
import 'package:flutter/material.dart';
import '../../render/ai_super_resolution.dart';
import '../../render/photo_ai_session.dart';
import '../../render/render_params.dart';

/// Both galleries edit a local configuration, preserving source temperatures.
class PhotoFilterControls extends StatelessWidget {
  final RenderParams params;
  final PhotoAiSession? ai;
  final int sourceWidth, sourceHeight;
  final ValueChanged<RenderParams> onChanged;
  const PhotoFilterControls({
    super.key,
    this.ai,
    this.sourceWidth = 0,
    this.sourceHeight = 0,
    required this.params,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final sliderWidth = constraints.maxWidth.clamp(0.0, 270.0);
          Widget slider(
            String title,
            double value,
            double min,
            double max,
            ValueChanged<double> update,
          ) => SizedBox(
            width: sliderWidth,
            child: Row(
              children: [
                Text(title, style: const TextStyle(fontSize: 11)),
                Expanded(
                  child: Slider(
                    value: value.clamp(min, max),
                    min: min,
                    max: max,
                    label: value.toStringAsFixed(2),
                    onChanged: update,
                  ),
                ),
                SizedBox(
                  width: 34,
                  child: Text(
                    value.toStringAsFixed(2),
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          );
          return Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilterChip(
                label: const Text('双边滤波'),
                selected: params.bilateralEnabled,
                visualDensity: VisualDensity.compact,
                onSelected: (v) =>
                    onChanged(params.copyWith(bilateralEnabled: v)),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('上采样', style: TextStyle(fontSize: 11)),
                  const SizedBox(width: 6),
                  DropdownButton<int>(
                    value: ai?.enabled == true
                        ? ai!.scale
                        : params.upsampleScale,
                    isDense: true,
                    items:
                        ({1, 2, 4, 8, 16, params.upsampleScale}.toList()
                              ..sort())
                            .map(
                              (v) => DropdownMenuItem(
                                value: v,
                                child: Text('$v×'),
                              ),
                            )
                            .toList(),
                    onChanged: ai?.enabled == true
                        ? null
                        : (v) {
                            if (v != null) {
                              onChanged(params.copyWith(upsampleScale: v));
                            }
                          },
                  ),
                ],
              ),
              DropdownButton<UpsampleMethod>(
                value: params.upsampleMethod,
                isDense: true,
                items: UpsampleMethod.values
                    .map(
                      (v) => DropdownMenuItem(
                        value: v,
                        child: Text(switch (v) {
                          UpsampleMethod.nearest => '最近邻',
                          UpsampleMethod.bilinear => '双线性',
                          UpsampleMethod.bicubic => '双三次',
                        }),
                      ),
                    )
                    .toList(),
                onChanged: ai?.enabled == true
                    ? null
                    : (v) {
                        if (v != null) {
                          onChanged(params.copyWith(upsampleMethod: v));
                        }
                      },
              ),
              if (ai != null) ...[
                Tooltip(
                  message:
                      '2× 使用原生 ESPCN；4× / 8× 级联运行同一模型。'
                      '仅增强显示，不增加真实测温分辨率。灰色倍率超出尺寸限制。',
                  child: DropdownButton<int>(
                    value: ai!.scale,
                    isDense: true,
                    items: [
                      const DropdownMenuItem(value: 0, child: Text('AI 超分：关闭')),
                      for (final scale in photoAiScales)
                        DropdownMenuItem(
                          value: scale,
                          enabled: supportsPhotoAiScale(
                            sourceWidth,
                            sourceHeight,
                            scale,
                          ),
                          child: Text(
                            'AI $scale× · ${scale == 2 ? "原生" : "级联"}实验',
                          ),
                        ),
                    ],
                    onChanged: Platform.isWindows || Platform.isAndroid
                        ? (value) {
                            if (value != null) ai!.setScale(value);
                          }
                        : null,
                  ),
                ),
                if (ai!.enabled)
                  Text(
                    ai!.busy
                        ? 'AI 处理中…'
                        : ai!.error != null
                        ? 'AI 失败，显示原预览'
                        : ai!.elapsedMs != null
                        ? '${ai!.elapsedMs} ms · 测温取自原数据'
                        : '等待增强…',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                if (ai!.enabled && ai!.error != null)
                  Tooltip(
                    message: ai!.error!,
                    child: const Icon(Icons.info_outline, size: 16),
                  ),
              ],
              if (params.bilateralEnabled) ...[
                slider(
                  'σ空间',
                  params.bilateralSigmaSpatial,
                  0.5,
                  4,
                  (v) => onChanged(params.copyWith(bilateralSigmaSpatial: v)),
                ),
                slider(
                  'σ亮度',
                  params.bilateralSigmaIntensity,
                  0.1,
                  5,
                  (v) => onChanged(params.copyWith(bilateralSigmaIntensity: v)),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
