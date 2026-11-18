# Thermal-PFT 实时性能优化（2026-11-18）

环境：RTX 5080、Windows、PyTorch 2.11.0+cu128。输入是已有的
`0000000A.temperature.csv`，120×90，PFT TV 输出 360×270，FP32。
基准旧实现为提交 `713382f`。以下是主机离线数据链路验证，未做 Flutter 页面测试、
未读取设备串口，也没有测量屏幕呈现 FPS 或传感器到屏幕的延迟。

| 预热后范围 | 原实现 | 优化后 |
| --- | ---: | ---: |
| Python 推理中位耗时，20 帧 | 94.73 ms | 74.36 ms |
| Python 推理 P95 | 100.13 ms | 75.70 ms |
| Python 推理吞吐 | 10.48 FPS | 13.44 FPS |
| Dart 实时会话完整链路，20 帧 | 8.15 FPS | 10.74 FPS |

完整链路包含预处理、进程通信、模型推理、输出校验及着色，不含页面绘制、串口或
传感器等待。先执行 3 帧再统计 20 帧。优化后最后一帧约 92 ms，其中预处理 6 ms、
worker 请求 76 ms（推理 75 ms）、着色 2 ms，余量为进程通信/调度等开销。
独立 Python 基准先预热 3 帧，再对 20 帧平移输入测试；新旧输出逐浮点值完全相同。
两轮完整链路最终 PNG 也一致，测温字段不变。

实现包括：按形状/设备复用注意力掩码，仅保留一份；CUDA event 查询完成进度，
去掉逐块强制同步；普通画面按原始帧、参数和可见光帧缓存，避免进度更新重复渲染。
状态栏显示实际 AI 完成速率；悬停可见最近一帧分段耗时。继续使用一帧在运行、
一帧待处理的队列，以最新画面优先，不通过积压或批处理提高表面吞吐。

试验过 CUDA Graph（缓存掩码后约 72 ms，对约 76 ms 的增益较小）和 FP16。
FP16 预热后可以更快，但与 FP32 的归一化输出最大差达到约 0.0105，因此本次未采用；
先前首次执行时间包含初始化，不能用来比较精度模式的持续帧率。未启用 TF32、
未更改权重或以降低分辨率换取速度。当前仍未达到 25 FPS，主要耗时仍在 PFT 推理。

复现工具：`tools/photo_ai/benchmark_stream.py` 支持用 `--implementation` 指定旧版本
适配器目录，`--weights` 指定同一权重，`--sample` 指定上述 CSV，`--output` 指定报告目录。
`tools/check_realtime_ai_display.dart` 使用 `THERMAL_SR_SAMPLE`、`THERMAL_AI_RUNTIME`、
`THERMAL_AI_RESULTS` 和 `THERMAL_AI_EXPECT_DEVICE=cuda` 验证完整链路。
本地逐帧报告及浮点输出位于 `build/ai-performance/`；这些大文件不进入版本库。

必要检查：13 项 Dart 非页面测试、5 项 Python 适配器测试、两组实际 CUDA 对比通过。
静态分析只保留实时页面原有的 4 项诊断，无新增诊断。

Windows Release 构建通过，已核对发布目录中的 engine、worker、PFT 适配器与仓库源码一致。
