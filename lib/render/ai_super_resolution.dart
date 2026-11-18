import 'dart:isolate';
import 'dart:typed_data';
import '../fusion/fusion.dart';
import 'render_params.dart';
import 'render_pipeline.dart';
import 'photo_ai_model.dart';
import 'photo_ai_runtime.dart';
import 'photo_ai_progress.dart';

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
  final PhotoAiModel aiModel;
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
    this.aiScale = 3,
    this.aiModel = PhotoAiModel.pftTv,
  });

  PhotoRenderInput withAiScale(int scale, {PhotoAiModel? model}) =>
      PhotoRenderInput(
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
        aiModel: model ?? aiModel,
      );

  bool get supportsAiScale => aiModel.supports(
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

  (RenderedFrame, RenderedFrame) _prepareAi() {
    final measured = render(scale: aiScale);
    final source = renderPipeline(
      thermalFrame: temperatures,
      srcW: width,
      srcH: height,
      params: params.copyWith(upsampleScale: 1, fusion: const FusionParams()),
      minOverride: measured.tMin,
      maxOverride: measured.tMax,
    );
    return (measured, source);
  }

  Future<RenderedFrame> enhanceAsync({
    PhotoAiProgressCallback? onProgress,
  }) async {
    if (!supportsAiScale) throw const FormatException('当前照片不支持此模型倍率');
    onProgress?.call(const PhotoAiProgress('preprocess'));
    final (measured, source) = await Isolate.run(_prepareAi);
    PhotoAiProgress? latest;
    final enhanced = await PhotoAiRuntime.shared.infer(
      aiModel,
      source.normalizedField,
      source.width,
      source.height,
      onProgress: (progress) {
        latest = progress;
        onProgress?.call(progress);
      },
    );
    onProgress?.call(
      PhotoAiProgress(
        'coloring',
        device: latest?.device,
        fallback: latest?.fallback,
      ),
    );
    final result = await Isolate.run(
      _AiColorTask(this, measured, enhanced).run,
    );
    onProgress?.call(
      PhotoAiProgress(
        'complete',
        device: latest?.device,
        fallback: latest?.fallback,
      ),
    );
    return result;
  }
}

// A value-only task prevents the UI progress callback being captured by an isolate.
class _AiColorTask {
  final PhotoRenderInput input;
  final RenderedFrame measured;
  final Float32List enhanced;
  const _AiColorTask(this.input, this.measured, this.enhanced);
  RenderedFrame run() => applyAiDisplay(
    measured,
    enhanced,
    input.params,
    visibleRgb: input.visibleRgb,
    visibleW: input.visibleW,
    visibleH: input.visibleH,
  );
}
