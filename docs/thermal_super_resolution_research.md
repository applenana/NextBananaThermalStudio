# 热像专用超分模型调研

核查日期：2026-11-18。这里讨论单张图片的空间超分，不是视频时间插帧。
本次只扩展现有 ESPCN 的照片实验倍率；下列热像模型尚未集成或在 CB360 样本上运行。

## 候选模型

| 模型 | 热像训练与输入 | 倍率 / 权重 | 工程判断 |
| --- | --- | --- | --- |
| Thermal-PFT light | 在 CIDIS 热像上微调 PFT；单图推理，另有训练时使用 RGB 监督的变体 | 热像微调权重仅原生 3×；提供 L1、L1 + cross-channel + TV 两套 Hugging Face 权重 | 首选离线试验 L1 版：公开权重和模型卡较齐全，不需要 CB360 提供可见光。需评估 PyTorch、自定义算子及移植成本 |
| PBVS_TSR / SwinFIR | 面向 PBVS 2025 单热图超分，训练包括合成数据与真实热像 | 测试脚本 scale=8；README 提供 Google Drive 模型和测试配置 | 值得作为原生 8× 对照；训练依赖较旧，尚未下载/验证外链权重或在本机测速度 |
| SwinFuSR | RGB 引导热像超分；另有训练时随机移除 RGB 的变体 | README 提供 8× / 16× 配置；release 含 baseline、large、modality-augmentation 权重 | 常规路径需要配准可见光，不适合作为 CB360 当前单热像流程的直接替换；缺失 RGB 变体需单独验证 |

许可证核查：Thermal-PFT 仓库 LICENSE.txt 为 Apache-2.0，L1 模型卡也声明
Apache-2.0；PBVS_TSR 仓库为 MIT；SwinFuSR 仓库为 Apache-2.0。
仓库许可不替代对具体下载权重、数据集及衍生依赖条款的核查。

Thermal-PFT README 的数据预处理步骤存在需澄清之处：文字写 3×，同时示例
出现 64→256，且描述从低分辨率图上采样生成 GT。因此不把其报告的 PSNR/SSIM
作为 CB360 效果保证。优先做相同输入、相同归一化、相同调色板的实际对照。
本次核查了仓库和模型文件列表，尚未验证热像权重推理结果。

## 接入边界

- 输入采用调色前的归一化灰度热像，避免把等离子伪彩色误当成原始热像。
- 输出只参与显示；源温度、测点、极值、报警和温度文件仍由原测温链路负责。
- 新模型必须明确原生倍率；不得把普通图像预训练权重或级联倍率称为热像专用权重。
- 先使用照片 `0000000A` 与普通插值 / ESPCN 对比，再决定是否引入额外运行时。
  该照片没有高分辨率真值，只能比较观感、稳定性和耗时，不能证明恢复了真实细节。

## 本次已实现的倍率实验

下拉列表为关闭、2× 原生 ESPCN、4× 级联、8× 级联，默认关闭。
仍使用普通图像训练的现有模型。CB360 的 120×90 对应输出 240×180、480×360、
960×720。其他设备按尺寸限制禁用超限倍率，现有默认颜色映射不变。

使用上次下载目录最后一个 ID `0000000A` 的温度 CSV 测试所有三档，单次流水线
耗时为 77 / 253 / 1009 ms，不含 PNG 编码、隔离线程启动与页面显示开销。
温度数组未被修改，测温场、范围和色标与同倍率普通渲染一致。
导出图观察到边缘更平滑，细节提升有限，高倍率可能继续平滑和累积伪影。

复现：设置 `THERMAL_SR_LIBRARY` 为构建好的推理 DLL，设置 `THERMAL_SR_SAMPLE`
为 `0000000A.temperature.csv`，运行 `flutter test --no-pub tools/check_ai_photo.dart`。
结果位于忽略的 `build/ai-photo-check/`：`result.json`、`comparison.png`、
`regular2x/4x/8x.png` 和 `ai2x/4x/8x.png`。
总览图统一显示尺寸，原生分辨率效果应打开各倍率单独文件查看。

## 一手来源

- Thermal-PFT：[作者仓库](https://github.com/guillepinto/THERMAL-PFT-SR)、
  [L1 权重](https://huggingface.co/SemilleroCV/thermal-pft-light-srx3)、
  [cross-channel + TV 权重](https://huggingface.co/SemilleroCV/thermal-pft-light-srx3-cross-channel-tv)。
  L1 模型仓库核查时 revision：`5002f089dcbd43c6835620136e0c0318707276cf`。
- PBVS_TSR：[作者仓库及权重入口](https://github.com/Raojiyong/PBVS_TSR)。
- SwinFuSR：[作者仓库](https://github.com/VisionICLab/SwinFuSR)、
  [权重发布页](https://github.com/VisionICLab/SwinFuSR/releases)、
  [论文](https://arxiv.org/abs/2404.14533)。
