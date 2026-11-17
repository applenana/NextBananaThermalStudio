enum PhotoAiModel {
  espcn('espcn', 'ESPCN · 通用轻量', [2, 4, 8]),
  pftL1('pft_l1', 'Thermal-PFT · 热像 L1', [3]),
  pftTv('pft_tv', 'Thermal-PFT · 热像 TV', [3]),
  pbvs('pbvs', 'DRCT-L · PBVS 热像', [8]),
  swinfu('swinfu', 'SwinFuSR · 无可见光', [8]);

  final String id, label;
  final List<int> scales;
  const PhotoAiModel(this.id, this.label, this.scales);
  bool get external => this != espcn;
  String get description => switch (this) {
    espcn => '普通图像训练；2× 原生，4× / 8× 级联。',
    pftL1 => '热像微调的原生 3×，使用 L1 权重。',
    pftTv => '热像微调的原生 3×，使用跨通道监督和 TV 损失权重。',
    pbvs => 'PBVS 2025 热像微调 DRCT-L，原生 8×；处理较慢。',
    swinfu => '热像 8×，采用 robust03 的零可见光引导路径；分块推理较慢。',
  };

  bool supports(int width, int height, int scale) =>
      scales.contains(scale) &&
      width > 0 &&
      height > 0 &&
      width * scale <= 1024 &&
      height * scale <= 1024;
}
