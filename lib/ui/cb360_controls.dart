import 'package:flutter/material.dart';
import '../cb360/controller.dart';

/// Compact status inside the common connection bar; baud selection lives there.
class Cb360Controls extends StatelessWidget {
  final Cb360Controller device;
  const Cb360Controls({super.key, required this.device});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: device,
    builder: (context, _) {
      final d = device;
      final theme = Theme.of(context);
      final age = d.parametersAcquiredAt == null
          ? '未获取'
          : '${DateTime.now().difference(d.parametersAcquiredAt!).inSeconds} 秒前';
      return Wrap(
        spacing: 10,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Tooltip(
            message: '曲线 ${d.liveCurveIndex ?? "—"} · CRC 错误 ${d.crcErrors}',
            child: Text(
              'CB360 · ${d.fps.toStringAsFixed(1)} fps · BP64 ${d.ratio.toStringAsFixed(2)}:1',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Tooltip(
            message: '按已获取参数计算全部像素温度。设备校准或设置变化后请刷新。参数：$age',
            child: TextButton.icon(
              onPressed: d.busy
                  ? null
                  : () async {
                      try {
                        await d.refresh();
                      } catch (error) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(SnackBar(content: Text('$error')));
                        }
                      }
                    },
              icon: d.busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('刷新测温参数'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
          ),
          if (d.error != null)
            Tooltip(
              message: d.error!,
              child: Icon(
                Icons.error_outline,
                size: 18,
                color: theme.colorScheme.error,
              ),
            ),
        ],
      );
    },
  );
}
