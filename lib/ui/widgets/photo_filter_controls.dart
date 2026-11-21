import 'package:flutter/material.dart';
import '../../render/photo_ai_model.dart';
import '../../render/photo_ai_runtime.dart';
import '../../render/photo_ai_session.dart';
import '../../render/render_params.dart';
import '../ai_runtime_install_ui.dart';

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
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: PhotoAiRuntime.revision,
    builder: (context, _, _) => _buildControls(context),
  );

  Widget _buildControls(BuildContext context) {
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
                        ({1, 2, 3, 4, 8, 16, params.upsampleScale}.toList()
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
                if (!PhotoAiRuntime.available(ai!.model))
                  const AiRuntimeInstallButton(),
                Tooltip(
                  message: '${ai!.model.description} 仅增强显示，测温取自原数据。',
                  child: DropdownButton<PhotoAiModel>(
                    value: ai!.model,
                    isDense: true,
                    items: PhotoAiModel.platformModels
                        .map(
                          (model) => DropdownMenuItem(
                            value: model,
                            enabled: PhotoAiRuntime.available(model),
                            child: Text(
                              '${model.label}${PhotoAiRuntime.available(model) ? "" : "（未安装）"}',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (model) {
                      if (model != null) ai!.setModel(model);
                    },
                  ),
                ),
                Tooltip(
                  message:
                      '${ai!.model.description}'
                      '仅增强显示，不增加真实测温分辨率。灰色倍率超出尺寸限制。',
                  child: DropdownButton<int>(
                    value: ai!.scale,
                    isDense: true,
                    items: [
                      const DropdownMenuItem(value: 0, child: Text('AI 超分：关闭')),
                      for (final scale in ai!.model.scales)
                        DropdownMenuItem(
                          value: scale,
                          enabled: ai!.model.supports(
                            sourceWidth,
                            sourceHeight,
                            scale,
                          ),
                          child: Text('AI 超分：$scale×'),
                        ),
                    ],
                    onChanged: PhotoAiRuntime.available(ai!.model)
                        ? (value) {
                            if (value != null) ai!.setScale(value);
                          }
                        : null,
                  ),
                ),
                if (ai!.processing)
                  SizedBox(
                    width: sliderWidth,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${ai!.progress?.backendLabel ?? ""} ${ai!.progress?.label ?? "等待 AI 任务"}'
                          '${ai!.progress?.fraction != null ? " · ${(ai!.progress!.fraction! * 100).round()}%" : ""}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(value: ai!.progress?.fraction),
                      ],
                    ),
                  ),
                if (ai!.enabled && !ai!.processing)
                  Text(
                    ai!.error != null
                        ? 'AI 失败，显示原预览'
                        : ai!.elapsedMs != null
                        ? '${ai!.progress?.backendLabel ?? ""} ${ai!.elapsedMs} ms · 测温取自原数据'
                        : '等待增强…',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                if (ai!.progress?.fallback != null)
                  Tooltip(
                    message: ai!.progress!.fallback!,
                    child: const Text(
                      'GPU 不可用，已回退 CPU',
                      style: TextStyle(fontSize: 11),
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
