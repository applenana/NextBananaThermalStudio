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
| `streaming stoped\n` | 上位机 → 设备 | **停止**热成像帧推流 |
| `vstream\n` | 上位机 → 设备 | **启动**可见光帧推流（同时作为保活心跳，每 500 ms 重发一次） |
| `vstream stoped\n` | 上位机 → 设备 | **停止**可见光帧推流 |

> **保活机制**：固件内置超时保护，若超过约 1 秒未收到对应推流命令，设备自动停止推流。上位机须以 500 ms 间隔持续重发 `stream` / `vstream` 心跳，直到用户主动关闭为止。

### 典型时序

```
上位机                                   设备
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

**固定长度 3092 字节**

```
[0..4]   "BEGIN"      (5 bytes, ASCII magic)
[5..8]   T_max        (f32 LE, 摄氏度)
[9..12]  T_min        (f32 LE, 摄氏度)
[13..16] T_avg        (f32 LE, 摄氏度)
[17..3088] pixels     (768 × f32 LE, 24×32 行优先, 摄氏度)
[3089..3091] "END"    (3 bytes, ASCII magic)
```

- 像素矩阵：行优先，24 行 × 32 列（默认方向）
- 字节序：小端（Little-Endian）
- 不含时间戳；帧率由串口波特率与设备发送节奏决定

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

## 参考实现

| 端 | 文件 |
|---|---|
| Dart 解析器 | `lib/protocol/frame_parser.dart` |
| Python 解析器 | BananaThermal Studio `frame_parser.py` |
| 固件 | `src/streaming.h`（RP2040 端）|
