import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import '../fusion/fusion.dart';
import 'render_params.dart';
import 'render_pipeline.dart';

typedef _Native = Int32 Function(Pointer<Float>, Int32, Int32, Pointer<Float>);
typedef _Infer = int Function(Pointer<Float>, int, int, Pointer<Float>);

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
  });

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
    final measured = render(scale: 2);
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
      espcnX2(source.normalizedField, source.width, source.height),
      params,
      visibleRgb: visibleRgb,
      visibleW: visibleW,
      visibleH: visibleH,
    );
  }
}
