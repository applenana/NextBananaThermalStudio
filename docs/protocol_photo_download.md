# 香蕉泥热成像图片下载协议

欢迎使用我们的协议！本协议设计简单易用，已在多款热成像模组上试装通过。

---

## 概述

图片下载协议用于通过串口命令 `download <filename>` 从设备读取一帧完整数据文件。文件格式随固件版本演进，上位机解码器兼容以下三种格式。

---

## 格式 v1 Simple（无元数据）

适用场景：早期固件，无 mode / dataFormat 元数据字段。

```
[0..3]   T_max   (f32 LE, 摄氏度)
[4..7]   T_min   (f32 LE, 摄氏度)
[8..]    pixels  (768 × f32 LE, 24×32 行优先, 摄氏度)
```

总大小：8 + 768 × 4 = **3080 字节**

---

## 格式 v1 Full（含模式标志）

适用场景：元数据含 `mode` 与 `dataFormat` 字段。

```
[0..3]   T_max        (f32 LE)
[4..7]   T_min        (f32 LE)
[8]      full_screen  (u8, 1=24×32, 0=32×32)
[9..]    pixels       (768 或 1024 × f32 LE)
```

- `full_screen=1`：24×32 → 768 浮点
- `full_screen=0`：32×32 → 1024 浮点

---

## 格式 v2 HTPH（双光融合）

适用场景：v2 固件，含可见光 RGB565 数据。

magic 标识：文件头 4 字节 = `0x48 0x54 0x50 0x48`（ASCII `HTPH`）

```
[0..3]   "HTPH"  magic (4 bytes)
[4]      ver     (u8, 版本号)
[5]      flags   (u8)
            bit0 = full_screen   (1=24×32, 0=32×32)
            bit1 = has_visible   (1=含可见光)
            bit2..3 = fusion_mode (0=OFF, 1=EDGE, 2=BLEND, 仅记录拍摄状态, 解码侧忽略)
[6..9]   T_max   (f32 LE)
[10..13] T_min   (f32 LE)
— 若 has_visible=1，紧跟可见光尺寸 —
[14..15] vis_width   (u16 LE)
[16..17] vis_height  (u16 LE)
— 热成像像素场 —
[cursor..]  pixels  (768 或 1024 × f32 LE, 由 full_screen 决定)
— 可见光像素（仅 has_visible=1）—
[cursor+thermalBytes..] vis_pixels (vis_width × vis_height × 2 bytes, RGB565 LE)
```

上位机接收到 `vis_pixels` 后对其**顺时针旋转 90°** 再转为 RGB888，与实时通路方向一致。

---

## 共通解码规则

1. 所有浮点像素字段均为 **f32 小端**，单位摄氏度
2. 像素矩阵在解码器内**垂直镜像（flip V）**，以匹配相机物理安装方向
3. JPEG 文件以 `FF D8 FF` 开头，直接透传，不经浮点解码
4. 数据不足时解码器返回 `PhotoFormat.unknown`，不抛异常

---

## 文件命名惯例

设备端文件名示例：`IMG_001.bin`（热成像），`IMG_001.jpg`（JPEG）

元数据（JSON 旁路通道）中可携带 `mode`、`dataFormat`、`sn` 等字段，供 v1 分支选择全屏/方形模式。

---

## 参考实现

| 端 | 文件 |
|---|---|
| Dart 解码器 | `lib/protocol/photo_decoder.dart` |
| Python 解码器 | BananaThermal Studio `photo_decoder.py` |
| 固件 | `src/photo.h`（RP2040 端）|
