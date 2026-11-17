import 'package:flutter/material.dart';
import '../../render/render_params.dart';

/// Both galleries edit a local configuration, preserving source temperatures.
class PhotoFilterControls extends StatelessWidget {
  final RenderParams params;
  final ValueChanged<RenderParams> onChanged;
  const PhotoFilterControls({
    super.key,
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
                    value: params.upsampleScale,
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
                    onChanged: (v) {
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
                onChanged: (v) {
                  if (v != null) onChanged(params.copyWith(upsampleMethod: v));
                },
              ),
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
