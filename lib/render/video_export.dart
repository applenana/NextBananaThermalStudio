import 'dart:math' as math;
import 'dart:typed_data';

/// Preserve the gallery's nearest-neighbour display before H.264 chroma
/// subsampling and player scaling. This changes display size, not sensor detail.
int thermalVideoDisplayScale(int width, int height) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('Video dimensions must be positive');
  }
  return math.max(1, (720 / math.min(width, height)).ceil());
}

Uint8List scaleVideoRgba(Uint8List rgba, int width, int height, int scale) {
  if (width <= 0 ||
      height <= 0 ||
      scale < 1 ||
      rgba.length != width * height * 4) {
    throw ArgumentError('Invalid RGBA frame or scale');
  }
  if (scale == 1) return rgba;
  final stride = width * scale * 4;
  final output = Uint8List(stride * height * scale);
  for (var y = 0; y < height; y++) {
    final row = y * scale * stride;
    for (var x = 0; x < width; x++) {
      final source = (y * width + x) * 4;
      for (var dx = 0; dx < scale; dx++) {
        final target = row + (x * scale + dx) * 4;
        output.setRange(target, target + 4, rgba, source);
      }
    }
    for (var dy = 1; dy < scale; dy++) {
      output.setRange(row + dy * stride, row + (dy + 1) * stride, output, row);
    }
  }
  return output;
}

/// Hardware encoders expose bitrate rather than x264's constant-quality mode.
int videoExportBitrate(int width, int height, int fps) =>
    (width * height * fps * 0.24).round().clamp(4000000, 20000000);

List<String> videoExportFfmpegArgs({
  required int width,
  required int height,
  required int fps,
  required String outputPath,
}) => [
  '-hide_banner',
  '-loglevel',
  'error',
  '-y',
  '-f',
  'rawvideo',
  '-pix_fmt',
  'rgba',
  '-s',
  '${width}x$height',
  '-r',
  '$fps',
  '-i',
  'pipe:0',
  '-c:v',
  'libx264',
  '-pix_fmt',
  'yuv420p',
  '-preset',
  'medium',
  '-crf',
  '18',
  '-movflags',
  '+faststart',
  outputPath,
];
