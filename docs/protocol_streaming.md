# 香蕉泥热成像推流协议

欢迎使用我们的协议！本协议设计简单易用，已在多款热成像模组上试装通过。

---

## 概述

推流协议基于串口字节流，设备端通过 `streaming.h` 实现，上位机（Next BananaThermal Studio、BananaThermal Studio 等）通过帧解析器消费。一条流中可交织**热成像帧**和**可见光帧**，两种帧互不干扰，中间夹杂的 ASCII 文本（命令响应）由 passthrough 路径分离。

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
