import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import '../fusion/fusion.dart';
import 'render_params.dart';
import 'render_pipeline.dart';

typedef _Native = Int32 Function(Pointer<Float>, Int32, Int32, Pointer<Float>);
typedef _Infer = int Function(Pointer<Float>, int, int, Pointer<Float>);

const photoAiScales = [2, 4, 8];

/// Each native 2x pass accepts at most 512 pixels per input axis.
bool supportsPhotoAiScale(int width, int height, int scale) =>
    photoAiScales.contains(scale) &&
    width > 0 &&
    height > 0 &&
    width * (scale ~/ 2) <= 512 &&
    height * (scale ~/ 2) <= 512;

/// 4x/8x are repeated applications of the same trained 2x model.
Float32List espcnUpscale(
  Float32List normalized,
  int width,
  int height,
  int scale,
) {
  if (!supportsPhotoAiScale(width, height, scale)) {
    throw const FormatException('AI 倍率不支持或输入尺寸过大（输出每边最多 1024）');
  }
  var result = normalized;
  for (var factor = 1; factor < scale; factor *= 2) {
    result = espcnX2(result, width * factor, height * factor);
  }
  return result;
}

/// Native inference is called only from a worker isolate. The bundled model is
/// a pretrained ESPCN network, not an interpolation filter labelled as AI.
Float32List espcnX2(Float32List normalized, int width, int height) {
  if (width < 1 ||
      height < 1 ||
      width > 512 ||
      height > 512 ||
      normalized.length != width * height ||
      normalized.any((v) => !v.isFinite || v < 0 || v > 1)) {
    throw const FormatException('AI 超分输入无效或尺寸过大');
  }
  final library = DynamicLibrary.open(
    Platform.environment['THERMAL_SR_LIBRARY'] ??
        (Platform.isWindows
            ? '${File(Platform.resolvedExecutable).parent.path}/thermal_super_resolution.dll'
            : 'libthermal_super_resolution.so'),
  );
  final infer = library.lookupFunction<_Native, _Infer>('thermal_espcn_x2');
  final input = calloc<Float>(normalized.length);
  final output = calloc<Float>(normalized.length * 4);
  try {
    input.asTypedList(normalized.length).setAll(0, normalized);
    final result = infer(input, width, height, output);
    if (result != 0) throw StateError('AI 超分失败 ($result)');
    return Float32List.fromList(output.asTypedList(normalized.length * 4));
  } finally {
    calloc.free(input);
    calloc.free(output);
  }
}

/// Only replaces display RGB. Temperature buffers, ranges and color legend
/// belong to the ordinary render path and never depend on inferred values.
RenderedFrame applyAiDisplay(
  RenderedFrame measured,
  Float32List enhanced,
  RenderParams params, {
  Uint8List? visibleRgb,
  int visibleW = 0,
  int visibleH = 0,
}) {
  if (enhanced.length != measured.width * measured.height ||
      enhanced.any((v) => !v.isFinite || v < 0 || v > 1)) {
    throw const FormatException('AI 超分输出无效');
  }
  var rgb = colorize(
    normalized: enhanced,
    width: measured.width,
    height: measured.height,
    colormapName: params.colormapName,
    mappingCurve: params.mappingCurve,
    useCustomColors: params.useCustomColors,
    coldColor: params.coldColor,
    midColor: params.midColor,
    hotColor: params.hotColor,
  );
  if (visibleRgb != null &&
      visibleW > 0 &&
      visibleH > 0 &&
      params.fusion.mode != FusionMode.off) {
    rgb = fuse(
      thermalRgb: rgb,
      tw: measured.width,
      th: measured.height,
      visibleRgb: visibleRgb,
      vw: visibleW,
      vh: visibleH,
      params: params.fusion,
    );
  }
  return RenderedFrame(
    rgb: rgb,
    width: measured.width,
    height: measured.height,
    normalizedField: measured.normalizedField,
    temperatureField: measured.temperatureField,
    tMin: measured.tMin,
    tMax: measured.tMax,
    thermalColorScaleRgb: measured.thermalColorScaleRgb,
    hasFiniteTemperatureData: measured.hasFiniteTemperatureData,
  );
}

class PhotoRenderInput {
  final Float32List temperatures;
  final int width, height;
  final RenderParams params;
  final Uint8List? visibleRgb;
  final int visibleW, visibleH;
  final double? min, max;
  final int aiScale;
  const PhotoRenderInput({
    required this.temperatures,
    required this.width,
    required this.height,
    required this.params,
    this.visibleRgb,
    this.visibleW = 0,
    this.visibleH = 0,
    this.min,
    this.max,
    this.aiScale = 2,
  });

  PhotoRenderInput withAiScale(int scale) => PhotoRenderInput(
    temperatures: temperatures,
    width: width,
    height: height,
    params: params,
    visibleRgb: visibleRgb,
    visibleW: visibleW,
    visibleH: visibleH,
    min: min,
    max: max,
    aiScale: scale,
  );

  bool get supportsAiScale => supportsPhotoAiScale(
    width,
    params.thermalView.enabled &&
            params.thermalView.restoresMlxSquareChain &&
            width == 32 &&
            height == 24
        ? 32
        : height,
    aiScale,
  );

  RenderedFrame render({int? scale}) => renderPipeline(
    thermalFrame: temperatures,
    srcW: width,
    srcH: height,
    params: scale == null ? params : params.copyWith(upsampleScale: scale),
    visibleRgb: visibleRgb,
    visibleW: visibleW,
    visibleH: visibleH,
    minOverride: min,
    maxOverride: max,
  );

  RenderedFrame enhance() {
    // Reject oversized cascades before allocating any enlarged render buffers.
    if (!supportsAiScale) {
      throw const FormatException('当前照片不支持此 AI 倍率（输出每边最多 1024）');
    }
    final measured = render(scale: aiScale);
    // Use the same display range at source resolution, before palette mapping.
    final source = renderPipeline(
      thermalFrame: temperatures,
      srcW: width,
      srcH: height,
      params: params.copyWith(upsampleScale: 1, fusion: const FusionParams()),
      minOverride: measured.tMin,
      maxOverride: measured.tMax,
    );
    return applyAiDisplay(
      measured,
      espcnUpscale(
        source.normalizedField,
        source.width,
        source.height,
        aiScale,
      ),
      params,
      visibleRgb: visibleRgb,
      visibleW: visibleW,
      visibleH: visibleH,
    );
  }
}
