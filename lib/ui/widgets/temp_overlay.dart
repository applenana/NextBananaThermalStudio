/// 温度叠加小卡: 在图库详情主画面左上角以半透明形式显示
/// 当前帧的最高 / 最低 / 平均温度. 半透明圆角胶囊, 不挡画面.
///
/// - 视频回放: 每选中一帧调用一次, 跟随当前帧的统计.
/// - 图片单帧: 解码后一次性渲染.
/// - 默认开启, 用户可通过详情顶部的开关按钮关闭.
/// - 导出 PNG 时同样把这层叠加烘焙到位图里, 见 photo_download_tab._renderToPng.
library;

import 'package:flutter/material.dart';

class TempOverlay extends StatelessWidget {
  const TempOverlay({
    super.key,
    required this.tMax,
    required this.tMin,
    required this.tAvg,
    this.compact = false,
  });

  final double tMax;
  final double tMin;
  final double tAvg;

  /// Android 端使用紧凑布局: 字号小一号, 内边距更紧.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final double fontSize = compact ? 10.5 : 11.5;
    final double labelSize = compact ? 8.5 : 9;
    final double padH = compact ? 8 : 10;
    final double padV = compact ? 5 : 7;
    final double gap = compact ? 6 : 8;

    Widget item(String label, double v, Color color) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: labelSize,
                  fontWeight: FontWeight.w600,
                  height: 1.0,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                '${v.toStringAsFixed(1)}°',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: fontSize,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      );
    }

    return IgnorePointer(
      ignoring: true,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            item('MAX', tMax, const Color(0xFFFF6E40)),
            SizedBox(width: gap),
            item('MIN', tMin, const Color(0xFF40C4FF)),
            SizedBox(width: gap),
            item('AVG', tAvg, const Color(0xFFFFD740)),
          ],
        ),
      ),
    );
  }
}

/// 计算 thermal Float32List 的平均温度. 跳过非有限值.
double computeAvgC(List<double>? thermal) {
  if (thermal == null || thermal.isEmpty) return 0;
  double s = 0;
  int n = 0;
  for (final v in thermal) {
    if (v.isFinite) {
      s += v;
      n++;
    }
  }
  return n == 0 ? 0 : s / n;
}
