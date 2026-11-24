/// 把 RGB888 字节缓冲渲染到 widget 上, 自适应缩放, NEAREST 风格 (热像放大不模糊).
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../../render/frame_interpolation.dart';

/// 将 RGB888 (width*height*3 字节) 异步解码为 ui.Image 并显示.
///
/// At most one decode and one latest pending frame.
class RgbImageView extends StatefulWidget {
  final Uint8List? rgb;
  final int width;
  final int height;
  final BoxFit fit;
  final FilterQuality filterQuality;
  final Color background;
  final Widget? overlay;
  final bool interpolate;

  const RgbImageView({
    super.key,
    required this.rgb,
    required this.width,
    required this.height,
    this.fit = BoxFit.contain,
    this.filterQuality = FilterQuality.none,
    this.background = Colors.black,
    this.overlay,
    this.interpolate = false,
  });

  @override
  State<RgbImageView> createState() => _RgbImageViewState();
}

class _RgbImageViewState extends State<RgbImageView> {
  ui.Image? _image;
  ui.Image? _previous;
  MotionSample? _sample;
  MidpointFlow? _flow;
  Timer? _presentReal;
  final _clock = Stopwatch()..start();
  int? _lastInputUs;
  int _pendingUs = 0;
  int _sequence = 0, _lastPaint = -1, _paintCount = 0, _windowUs = 0;
  double? _paintFps;
  Uint8List? _pendingRgb;
  int _pendingW = 0, _pendingH = 0;
  bool _decoding = false;

  @override
  void didUpdateWidget(covariant RgbImageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.interpolate != widget.interpolate) {
      _clearPair();
      _sample = null;
      _lastInputUs = null;
      _windowUs = 0;
      _paintFps = null;
    }
    if (!identical(oldWidget.rgb, widget.rgb) ||
        oldWidget.width != widget.width ||
        oldWidget.height != widget.height) {
      _enqueue(widget.rgb, widget.width, widget.height);
    }
  }

  @override
  void initState() {
    super.initState();
    _enqueue(widget.rgb, widget.width, widget.height);
  }

  @override
  void dispose() {
    _clearPair();
    _image?.dispose();
    super.dispose();
  }

  void _clearPair() {
    _presentReal?.cancel();
    _presentReal = null;
    _previous?.dispose();
    _previous = null;
    _flow = null;
  }

  void _enqueue(Uint8List? rgb, int w, int h) {
    if (rgb == null || w <= 0 || h <= 0 || rgb.length != w * h * 3) return;
    _pendingRgb = rgb;
    _pendingW = w;
    _pendingH = h;
    _pendingUs = _clock.elapsedMicroseconds;
    if (_decoding) return;
    _decoding = true;
    scheduleMicrotask(_decodeLoop);
  }

  Future<void> _decodeLoop() async {
    while (_pendingRgb != null) {
      final rgb = _pendingRgb!;
      final w = _pendingW;
      final h = _pendingH;
      final arrival = _pendingUs;
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
        rgba,
        w,
        h,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      final newImg = await completer.future;
      if (!mounted) {
        newImg.dispose();
        return;
      }
      final delta = arrival - (_lastInputUs ?? arrival);
      final sample = widget.interpolate
          ? MotionSample.fromRgb(rgb, w, h)
          : null;
      final old = _image;
      final canMatch =
          sample != null &&
          _sample != null &&
          old?.width == w &&
          old?.height == h &&
          _presentReal == null &&
          delta >= 32000 &&
          delta <= 240000 &&
          _clock.elapsedMicroseconds - arrival < delta ~/ 2;
      _clearPair();
      if (canMatch) _flow = MidpointFlow.estimate(_sample!, sample);
      _lastInputUs = arrival;
      _sample = sample;
      final hold =
          (delta ~/ 2).clamp(0, 80000) - (_clock.elapsedMicroseconds - arrival);
      if (_flow != null && hold >= 8000) {
        _previous = old;
        _presentReal = Timer(Duration(microseconds: hold), () {
          if (mounted) setState(_clearPair);
        });
      } else {
        _flow = null;
        old?.dispose();
      }
      _sequence++;
      setState(() => _image = newImg);
    }
    _decoding = false;
  }

  // Count each distinct real/midpoint paint once, ignoring overlay redraws.
  void _recordPaint() {
    final id = _sequence * 2 + (_flow == null ? 1 : 0);
    if (id == _lastPaint) return;
    _lastPaint = id;
    final now = _clock.elapsedMicroseconds;
    if (_windowUs == 0 || now - _windowUs > 2000000) {
      _windowUs = now;
      _paintCount = 0;
    } else if (++_paintCount > 0 && now - _windowUs >= 1000000) {
      _paintFps = _paintCount * 1000000 / (now - _windowUs);
      _windowUs = now;
      _paintCount = 0;
    }
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
              painter: RgbFramePainter(
                image: _image!,
                previous: _previous,
                flow: _flow,
                fit: widget.fit,
                filterQuality: widget.filterQuality,
                onPaint: widget.interpolate ? _recordPaint : null,
              ),
            ),
          if (widget.interpolate && _paintFps != null)
            Positioned(
              top: 4,
              left: 4,
              child: IgnorePointer(
                child: ColoredBox(
                  color: Colors.black54,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      '显示 ${_paintFps!.toStringAsFixed(1)} FPS',
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ),
                ),
              ),
            ),
          if (widget.overlay != null) widget.overlay!,
        ],
      ),
    );
  }
}

class RgbFramePainter extends CustomPainter {
  final ui.Image image;
  final ui.Image? previous;
  final MidpointFlow? flow;
  final BoxFit fit;
  final FilterQuality filterQuality;
  final VoidCallback? onPaint;
  RgbFramePainter({
    required this.image,
    required this.previous,
    required this.flow,
    required this.fit,
    required this.filterQuality,
    this.onPaint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    onPaint?.call();
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
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
    if (flow == null || previous == null) {
      canvas.drawImageRect(image, src, dst, paint);
      return;
    }
    paint.filterQuality = FilterQuality.low;
    canvas.save();
    canvas.translate(dst.left, dst.top);
    canvas.scale(dst.width / image.width, dst.height / image.height);
    _warp(canvas, previous!, -1, paint);
    paint.color = const Color(0x80ffffff);
    _warp(canvas, image, 1, paint);
    canvas.restore();
  }

  static final _indices = Uint16List.fromList([
    for (var j = 0; j < MidpointFlow.rows - 1; j++)
      for (var i = 0; i < MidpointFlow.cols - 1; i++)
        for (final offset in [
          0,
          1,
          MidpointFlow.cols,
          1,
          MidpointFlow.cols + 1,
          MidpointFlow.cols,
        ])
          j * MidpointFlow.cols + i + offset,
  ]);
  static final _identity = Matrix4.identity().storage;

  void _warp(Canvas canvas, ui.Image texture, int direction, Paint paint) {
    const cols = MidpointFlow.cols, rows = MidpointFlow.rows;
    final pos = Float32List(cols * rows * 2), uv = Float32List(cols * rows * 2);
    for (int k = 0; k < cols * rows; k++) {
      final x = (k % cols) * texture.width / (cols - 1),
          y = (k ~/ cols) * texture.height / (rows - 1);
      pos[2 * k] = x;
      pos[2 * k + 1] = y;
      uv[2 * k] =
          x + direction * flow!.dx[k] * texture.width / MotionSample.width;
      uv[2 * k + 1] =
          y + direction * flow!.dy[k] * texture.height / MotionSample.height;
    }
    final mesh = ui.Vertices.raw(
      ui.VertexMode.triangles,
      pos,
      textureCoordinates: uv,
      indices: _indices,
    );
    final shader = ui.ImageShader(
      texture,
      TileMode.clamp,
      TileMode.clamp,
      _identity,
      filterQuality: FilterQuality.low,
    );
    paint.shader = shader;
    canvas.drawVertices(mesh, BlendMode.srcOver, paint);
    mesh.dispose();
    shader.dispose();
  }

  @override
  bool shouldRepaint(covariant RgbFramePainter old) =>
      old.image != image ||
      old.flow != flow ||
      old.fit != fit ||
      old.filterQuality != filterQuality;
}
