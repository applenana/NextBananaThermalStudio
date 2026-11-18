> 历史研究记录：当前应用仅保留 Thermal-PFT L1 / TV 3×。ESPCN、DRCT/PBVS、SwinFuSR 已移除。当前用法见 tools/photo_ai/MODELS.md。

# 热像专用超分模型调研

核查日期：2026-11-18。这里讨论单张图片的空间超分，不是视频时间插帧。
后续实现已将下列三个系列接入 Windows 照片模型下拉框，并在最后一张 CB360
照片 `0000000A` 上完成实际推理。详细来源、预处理、限制和测时见
[`tools/photo_ai/MODELS.md`](../tools/photo_ai/MODELS.md)。

## 候选模型

| 模型 | 热像训练与输入 | 倍率 / 权重 | 工程判断 |
| --- | --- | --- | --- |
| Thermal-PFT light | 在 CIDIS 热像上微调 PFT；单图推理，另有训练时使用 RGB 监督的变体 | 热像微调权重仅原生 3×；提供 L1、L1 + cross-channel + TV 两套 Hugging Face 权重 | 已接入 L1 和 cross-channel + TV 两版，本地 PyTorch 优先使用 CUDA；不需要可见光 |
| PBVS_TSR / DRCT-L | 面向 PBVS 2025 单热图超分，训练包括合成数据与真实热像 | 测试脚本 scale=8；README 提供 Google Drive 模型和测试配置 | 已接入最终 8× 输出；源码核查更正原先的 SwinFIR 标注 |
| SwinFuSR | RGB 引导热像超分；另有训练时随机移除 RGB 的变体 | README 提供 8× / 16× 配置；release 含 baseline、large、modality-augmentation 权重 | 已接入 robust03 的零可见光路径；CPU 分块推理较慢，不默认启用 |

许可证核查：Thermal-PFT 仓库 LICENSE.txt 为 Apache-2.0，L1 模型卡也声明
Apache-2.0；PBVS_TSR 仓库为 MIT；SwinFuSR 仓库为 Apache-2.0。
仓库许可不替代对具体下载权重、数据集及衍生依赖条款的核查。

Thermal-PFT README 的数据预处理步骤存在需澄清之处：文字写 3×，同时示例
出现 64→256，且描述从低分辨率图上采样生成 GT。因此不把其报告的 PSNR/SSIM
作为 CB360 效果保证。优先做相同输入、相同归一化、相同调色板的实际对照。
PFT 两套 3× 权重、DRCT-L 8×、SwinFuSR robust03 8× 已下载、记录哈希、严格加载并
实际推理。SwinFuSR 使用无可见光引导路径及分块处理，并不要求 CB360 提供 RGB。

## 接入边界

- 输入采用调色前的归一化灰度热像，避免把等离子伪彩色误当成原始热像。
- 输出只参与显示；源温度、测点、极值、报警和温度文件仍由原测温链路负责。
- 新模型必须明确原生倍率；不得把普通图像预训练权重或级联倍率称为热像专用权重。
- 使用照片 `0000000A` 与普通插值 / ESPCN 对比，Windows 扩展包默认包含本地 CUDA 运行时，并支持 CPU 回退。
  该照片没有高分辨率真值，只能比较观感、稳定性和耗时，不能证明恢复了真实细节。

## 初始 ESPCN 倍率实验

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

## 热像模型接入结果

两处图库增加模型下拉框，选项为 ESPCN、Thermal-PFT L1、Thermal-PFT TV、
DRCT-L / PBVS、SwinFuSR 无可见光。倍率框与模型联动，PFT 固定原生 3×，
DRCT-L 和 SwinFuSR 固定 8×，ESPCN 保留 2/4/8×。默认仍关闭。
导出名包含模型 ID 和倍率，切换模型时旧结果不会覆盖新选择。

实际 CPU 测时（含模型加载；PFT L1 还含首次进程启动）：PFT L1 10.794 秒，
PFT TV 3.433 秒，DRCT-L 11.788 秒，SwinFuSR 61.917 秒。全部测温字段保持一致。
从导出图看，DRCT-L 的轮廓更平滑，PFT 边缘有伪影，SwinFuSR 的改善有限且较慢。
这些是单样本观感结论，不能证明恢复了真实细节。新输出在
`build/thermal-ai-comparison/`，复现入口为 `tools/check_thermal_ai_models.dart`。
仅对导出图进行了检查，没有进行 Flutter 页面测试。

## 一手来源

- Thermal-PFT：[作者仓库](https://github.com/guillepinto/THERMAL-PFT-SR)、
  [L1 权重](https://huggingface.co/SemilleroCV/thermal-pft-light-srx3)、
  [cross-channel + TV 权重](https://huggingface.co/SemilleroCV/thermal-pft-light-srx3-cross-channel-tv)。
  L1 模型仓库核查时 revision：`5002f089dcbd43c6835620136e0c0318707276cf`。
- PBVS_TSR：[作者仓库及权重入口](https://github.com/Raojiyong/PBVS_TSR)。
- SwinFuSR：[作者仓库](https://github.com/VisionICLab/SwinFuSR)、
  [权重发布页](https://github.com/VisionICLab/SwinFuSR/releases)、
  [论文](https://arxiv.org/abs/2404.14533)。
