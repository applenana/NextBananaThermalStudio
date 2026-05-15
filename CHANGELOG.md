# Changelog

本项目所有显著变更记录于此。版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)，发布日志按时间倒序。

## [v0.2.3] - 2026-05-15

### 修复 (Fixed)
- **串口首次连接收不到数据**：`SerialService.open()` 与后台探测 `_probeDeviceCore()` 打开串口后未显式拉高 DTR / RTS，导致 RP2040 + TinyUSB CDC 固件因 `cdc_connected = false` 丢弃所有 TX。表现为必须先用浏览器 Web Serial「预热」一次才能正常收包。现强制 `dtr = on`、`rts = on`，开箱即用。

### 优化 (Changed)
- **默认窗口尺寸由 935×755 加宽至 1280×820**：原尺寸下实时 Tab 右侧列在多处出现 `RenderFlex overflowed` 警告，新默认值给列表 / 按钮 / 控制台留足空间。已通过 `SharedPreferences` 持久化旧尺寸的用户不受影响（可在设置里恢复默认）。
- `windows/runner/main.cpp` 注释统一改为英文，避免 MSVC 在 CP936 代码页下将 C4819 提升为 error 阻断构建。

## [v0.2.2] - 历史版本

- fix(serial): 改用 `Isolate.spawn` 顶层 entry 让探测进度消息正常回主线程。

## [v0.2.1] - 历史版本

- perf(serial): 串口探测放进后台 isolate 避免卡 UI。

## [v0.2.0] - 历史版本

- feat(ui): 窄屏模式底部导航栏适配。
- docs: 截图改为并排表格布局；README 加入实时与图库截图。

## [v0.1.1] - 历史版本

- feat: 启动闪屏 / 自动连接 / 掉线重连 / 连接栏布局重构。

## [v0.1.0] - 历史版本

- feat: 从 Python/Tk 上位机迁移到 Flutter，并接入 CI workflow 与 README。
