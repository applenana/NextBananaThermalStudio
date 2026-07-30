# 香蕉泥热成像推流协议

欢迎使用我们的协议！本协议设计简单易用，已在多款热成像模组上试装通过。

---

## 概述

推流协议基于串口字节流，设备端通过 `streaming.h` 实现，上位机（Next BananaThermal Studio、BananaThermal Studio 等）通过帧解析器消费。一条流中可交织**热成像帧**和**可见光帧**，两种帧互不干扰，中间夹杂的 ASCII 文本（命令响应）由 passthrough 路径分离。

---

## 触发推流 / 停止推流

上位机通过串口发送 ASCII 命令行（以 `\n` 结尾）控制推流开关。

| 命令 | 方向 | 含义 |
|---|---|---|
| `stream\n` | 上位机 → 设备 | **启动**热成像帧推流（同时作为保活心跳，每 500 ms 重发一次） |
| `thermal view\n` | 上位机 → 设备 | 查询传感器、屏幕模式、热流尺寸和视图参数 |
| `streaming stoped\n` | 上位机 → 设备 | **停止**热成像帧推流 |
| `vstream\n` | 上位机 → 设备 | **启动**可见光帧推流（同时作为保活心跳，每 500 ms 重发一次） |
| `vstream stoped\n` | 上位机 → 设备 | **停止**可见光帧推流 |

> **保活机制**：固件内置超时保护，若超过约 1 秒未收到对应推流命令，设备自动停止推流。上位机须以 500 ms 间隔持续重发 `stream` / `vstream` 心跳，直到用户主动关闭为止。

### 热像视图参数同步

上位机每次开启热成像画面时，必须先发送 `thermal view\n`。设备返回单行
UTF-8/ASCII JSON，随后才启动热帧推流：

```json
{"type":"thermal_view","version":2,"sensor":"mlx90640","screen_mode":"square","visible_width":120,"visible_height":120,"thermal_width":32,"thermal_height":24,"thermal_count":768,"display_width":240,"display_height":240,"x_offset":0,"y_offset":0,"scale":1.3,"sensor_rotate180":true}
```

- `sensor`：`heimann_htpa32x32` / `mlx90640` / `mlx90641`
- `screen_mode`：`fullscreen` / `square`
- `visible_width/height`：可见光线上尺寸，仅用于预告和校验；每个 VBEG 帧头仍是权威尺寸
- `thermal_width/height/count`：后续 BEGIN 帧的温度矩阵尺寸和 float 数量
- `display_width/height`：设备当前热像目标画布
- `x_offset`：热成像 X 偏移，单位为设备屏幕像素，范围 `-100..100`
- `y_offset`：热成像 Y 偏移，单位为设备屏幕像素，范围 `-100..100`
- `scale`：热成像缩放，范围 `1.0..2.0`
- 每 `10` 个偏移单位对应 `1` 个热传感器源像素
- `sensor_rotate180`：复原 MLX 方屏逻辑容器所需的设备方向

热流尺寸规则：全屏始终 `32×24`；方屏 MLX 仍为 `32×24`；方屏 Heimann
为真实 `32×32`。上位机负责用传感器、屏幕模式、旋转、缩放和偏移复原
设备显示链。未收到合法响应时按旧协议 `32×24 / 768 floats` 解析。

### 典型时序

```
上位机                                   设备
  |──── thermal view\n ────────────────────>|
  |<─── {"type":"thermal_view",...}\n ──────|
  |──── stream\n ──────────────────────────>|
  |                        BEGIN...END (热帧)|
  |──── stream\n ──────────────────────────>|  ← 500 ms 心跳
  |                        BEGIN...END (热帧)|
  |──── vstream\n ─────────────────────────>|
  |                        VBEG...VEND (可见)|
  |──── vstream stoped\n ──────────────────>|
  |──── streaming stoped\n ────────────────>|
```

---

## 热成像帧

**帧外壳固定，像素数量由最近一次有效 `thermal view` 决定**

```
[0..4]   "BEGIN"      (5 bytes, ASCII magic)
[5..8]   T_max        (f32 LE, 摄氏度)
[9..12]  T_min        (f32 LE, 摄氏度)
[13..16] T_avg        (f32 LE, 摄氏度)
[17..]      pixels     (768 或 1024 × f32 LE, 行优先, 摄氏度)
[17+N*4..]  "END"      (3 bytes, ASCII magic)
```

- 像素矩阵：行优先，宽度恒为 32，高度为 24 或 32
- 字节序：小端（Little-Endian）
- 不含时间戳；帧率由串口波特率与设备发送节奏决定
- v2 上位机从 payload 重算 min/max/avg；头部三个字段保留旧协议结构

---

## 可见光帧

**变长**

```
[0..3]   "VBEG"       (4 bytes, ASCII magic)
[4..7]   width        (u32 LE, 像素列数)
[8..11]  height       (u32 LE, 像素行数)
[12..15] len          (u32 LE, 后续 RGB565 字节数 = width × height × 2)
[16..]   pixels       (len bytes, RGB565 LE, 行优先)
[16+len..] "VEND"     (4 bytes, ASCII magic)
```

- 最大 payload：120 × 160 × 2 = 38 400 字节
- 颜色格式：RGB565，小端
- 可见光帧与热成像帧在同一字节流中交织，解析器按 magic 独立识别

---

## 帧解析器行为

1. 扫描流中第一个 `BEGIN` 或 `VBEG` magic
2. magic 之前的字节作为 ASCII 文本（`onPassthrough` 回调）
3. 确认帧尾 magic (`END` / `VEND`) 存在后整帧出队
4. 缓冲区上限 512 KB，超出部分丢弃并计入 `droppedBytes`
5. 跨块边界：末尾 1~4 字节若可能是 magic 前缀，则暂留至下一 chunk

---

## 温度线性校准协议

设备最终输出温度使用下式校正：

```
T输出 = T传感器 × gain + offset
```

`gain` 与 `offset` 同时更新，`set` / `reset` 成功后立即写入 LittleFS。所有
响应都是单行 ASCII JSON，可以与热成像/可见光二进制帧交织。

| 命令 | 说明 |
|---|---|
| `calibration get` | 查询当前系数 |
| `calibration set <gain> <offset>` | 校验、原子更新并保存两个系数 |
| `calibration reset` | 恢复并保存 `gain=1.0, offset=0.0` |

成功响应：

```json
{"type":"temperature_calibration","version":1,"operation":"set","gain":1.01250000,"offset":-0.42000000,"persisted":true}
```

失败响应：

```json
{"type":"temperature_calibration","version":1,"operation":"set","error":"out_of_range"}
```

- `gain` 允许范围：`0.5..1.5`
- `offset` 允许范围：`-100..100` ℃
- `operation` 为 `get` / `set` / `reset`
- `persisted=true` 表示设备已完成配置文件写入
- 新上位机优先探测并使用本协议，以避免分两次更新和中文文本响应解析不稳定

### 新旧固件兼容策略

| 固件能力 | 上位机行为 | 写入保障 |
|---|---|---|
| 支持 `calibration ...` JSON v1 | 直接使用 v1 | 参数校验、双系数原子更新、保存结果确认 |
| 仅支持旧版 `cali ...` | v1 查询超时后自动降级 | 分别写入 `w0` / `b0`，执行 `save`，等待并回读校验 |
| 未知或无响应 | v1 与旧协议均探测失败后提示用户 | 不写入 |

旧协议查询响应为 `曲线信息: 权重1.00, 偏移0.00`。上位机会同时兼容完整
UTF-8 文本以及串口链路仅保留 ASCII 标点和数字的形式。为避免误把热像二进制
片段识别成参数，宽松解析只会在已发送 `cali -show` 且等待响应时启用。

旧协议有两项固有限制：

1. `gain` 与 `offset` 分两条命令更新，设备端无法保证原子性。
2. `cali -show` 只输出两位小数，因此回读校验精度约为 0.01。

校准向导会显示当前使用“v1 原子协议”还是“旧版兼容模式”。旧模式仍会做
范围校验、保存等待和回读比对，但建议在条件允许时升级到支持 v1 的固件。
同一连接会话中，上位机会保留自己刚写入的高精度系数，供再次校准时做系数组合；
应用重启后，旧固件只能重新提供两位小数，此精度限制无法由上位机可靠恢复。

### 重复校准的系数组合

设备已经校准过时，实时输出不再是传感器原始温度：

```
T当前 = T原始 × gain旧 + offset旧
```

向导采集的是 `T当前`，并根据参考温点拟合 `T参考 = a × T当前 + c`。写回设备前
会将两层线性关系组合，而不是直接用 `a`、`c` 覆盖已有系数：

```
gain新   = a × gain旧
offset新 = a × offset旧 + c
```

因此在 v1 协议可精确读取现有系数时，可以连续进行多次校准。旧协议在应用重启后
受两位小数回显限制，仍可重复校准，但累计精度不如 v1。

---

## 参考实现

| 端 | 文件 |
|---|---|
| Dart 解析器 | `lib/protocol/frame_parser.dart` |
| Dart 校准模型 | `lib/protocol/temperature_calibration.dart` |
| Python 解析器 | BananaThermal Studio `frame_parser.py` |
| 固件 | `src/streaming.h`、`src/temperature_calibration.h`（RP2040 端）|
