enum PhotoAiModel {
  pftL1('pft_l1', 'Thermal-PFT · L1', [3]),
  pftTv('pft_tv', 'Thermal-PFT · TV', [3]);

  final String id, label;
  final List<int> scales;
  const PhotoAiModel(this.id, this.label, this.scales);
  String get description => switch (this) {
    pftL1 => '热像微调的原生 3×，使用 L1 权重。',
    pftTv => '热像微调的原生 3×，使用跨通道监督和 TV 损失权重。',
  };

  bool supports(int width, int height, int scale) =>
      scales.contains(scale) &&
      width > 0 &&
      height > 0 &&
      width * scale <= 1024 &&
      height * scale <= 1024;
}
