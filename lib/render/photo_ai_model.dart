import 'dart:io';

enum PhotoAiModel {
  pftL1('pft_l1', 'Thermal-PFT · L1', [3]),
  pftTv('pft_tv', 'Thermal-PFT · TV', [3]),
  mobile3x('tiny3x', '移动轻量模型', [3]);

  static const windowsModels = [pftL1, pftTv];
  static List<PhotoAiModel> get platformModels =>
      Platform.isAndroid ? const [mobile3x] : windowsModels;
  static PhotoAiModel get platformDefault =>
      Platform.isAndroid ? mobile3x : pftTv;

  final String id, label;
  final List<int> scales;
  const PhotoAiModel(this.id, this.label, this.scales);
  String get inputLimit => this == mobile3x ? '输入须为 120×90' : '输出每边最多 1024';
  String get description => switch (this) {
    mobile3x => '内置轻量模型，适用于 120×90 热像。',
    pftL1 => '热像微调的原生 3×，使用 L1 权重。',
    pftTv => '热像微调的原生 3×，使用跨通道监督和 TV 损失权重。',
  };

  bool supports(int width, int height, int scale) =>
      scales.contains(scale) &&
      (this != mobile3x || (width == 120 && height == 90)) &&
      width > 0 &&
      height > 0 &&
      width * scale <= 1024 &&
      height * scale <= 1024;
}
