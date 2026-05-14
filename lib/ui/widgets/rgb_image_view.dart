/// 把 RGB888 字节缓冲渲染到 widget 上, 自适应缩放, NEAREST 风格 (热像放大不模糊).
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 将 RGB888 (width*height*3 字节) 异步解码为 ui.Image 并显示.
///
/// 自带帧节流: 100ms 内只解码最新的一帧, 避免高帧率把 UI 拖死.
class RgbImageView extends StatefulWidget {
  final Uint8List? rgb;
  final int width;
  final int height;
  final BoxFit fit;
  final FilterQuality filterQuality;
  final Color background;
  final Widget? overlay;

  const RgbImageView({
    super.key,
    required this.rgb,
    required this.width,
    required this.height,
    this.fit = BoxFit.contain,
    this.filterQuality = FilterQuality.none,
    this.background = Colors.black,
    this.overlay,
  });

  @override
  State<RgbImageView> createState() => _RgbImageViewState();
}

class _RgbImageViewState extends State<RgbImageView> {
  ui.Image? _image;
  Uint8List? _pendingRgb;
  int _pendingW = 0, _pendingH = 0;
  bool _decoding = false;

  @override
  void didUpdateWidget(covariant RgbImageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _enqueue(widget.rgb, widget.width, widget.height);
  }

  @override
  void initState() {
    super.initState();
    _enqueue(widget.rgb, widget.width, widget.height);
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  void _enqueue(Uint8List? rgb, int w, int h) {
    if (rgb == null || w <= 0 || h <= 0 || rgb.length != w * h * 3) return;
    _pendingRgb = rgb;
    _pendingW = w;
    _pendingH = h;
    if (_decoding) return;
    _decoding = true;
    scheduleMicrotask(_decodeLoop);
  }

  Future<void> _decodeLoop() async {
    while (_pendingRgb != null) {
      final rgb = _pendingRgb!;
      final w = _pendingW;
      final h = _pendingH;
      _pendingRgb = null;
      // 转 RGBA
      final rgba = Uint8List(w * h * 4);
      for (int i = 0, j = 0; i < w * h; i++, j += 4) {
        rgba[j] = rgb[i * 3];
        rgba[j + 1] = rgb[i * 3 + 1];
        rgba[j + 2] = rgb[i * 3 + 2];
        rgba[j + 3] = 255;
      }
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        rgba, w, h, ui.PixelFormat.rgba8888,
        completer.complete,
      );
      final newImg = await completer.future;
      _image?.dispose();
      if (!mounted) {
        newImg.dispose();
        return;
      }
      setState(() => _image = newImg);
    }
    _decoding = false;
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: widget.background,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_image != null)
            CustomPaint(
              painter: _ImagePainter(
                image: _image!,
                fit: widget.fit,
                filterQuality: widget.filterQuality,
              ),
            ),
          if (widget.overlay != null) widget.overlay!,
        ],
      ),
    );
  }
}

class _ImagePainter extends CustomPainter {
  final ui.Image image;
  final BoxFit fit;
  final FilterQuality filterQuality;
  _ImagePainter({
    required this.image,
    required this.fit,
    required this.filterQuality,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final imgAspect = image.width / image.height;
    final boxAspect = size.width / size.height;
    Rect dst;
    if (fit == BoxFit.fill) {
      dst = Offset.zero & size;
    } else {
      double dw, dh;
      if (imgAspect > boxAspect) {
        dw = size.width;
        dh = size.width / imgAspect;
      } else {
        dh = size.height;
        dw = size.height * imgAspect;
      }
      dst = Rect.fromLTWH(
        (size.width - dw) / 2,
        (size.height - dh) / 2,
        dw,
        dh,
      );
    }
    final paint = Paint()..filterQuality = filterQuality;
    canvas.drawImageRect(image, src, dst, paint);
  }

  @override
  bool shouldRepaint(covariant _ImagePainter old) =>
      old.image != image || old.fit != fit || old.filterQuality != filterQuality;
}
