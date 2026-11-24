/// Progress counts completed model blocks/tiles, not estimated remaining time.
class PhotoAiProgress {
  final String stage;
  final int? completed, total;
  final String? device, fallback;
  final int? prepareMs, requestMs, modelLoadMs, modelInferenceMs, colorMs;
  const PhotoAiProgress(
    this.stage, {
    this.completed,
    this.total,
    this.device,
    this.fallback,
    this.prepareMs,
    this.requestMs,
    this.modelLoadMs,
    this.modelInferenceMs,
    this.colorMs,
  });

  factory PhotoAiProgress.fromJson(Map<String, dynamic> json) {
    final stage = json['stage'];
    final done = json['completed'], total = json['total'];
    final invalidMetric =
        const [
          'prepareMs',
          'requestMs',
          'modelLoadMs',
          'modelInferenceMs',
          'colorMs',
        ].any((key) {
          final value = json[key];
          return value != null && (value is! int || value < 0);
        });
    if (stage is! String ||
        (done != null && done is! int) ||
        (total != null && total is! int) ||
        ((done == null) != (total == null)) ||
        (json['device'] != null && json['device'] is! String) ||
        (json['fallback'] != null && json['fallback'] is! String) ||
        invalidMetric ||
        (done != null &&
            (total == null || total <= 0 || done < 0 || done > total))) {
      throw const FormatException('AI 进度数据无效');
    }
    return PhotoAiProgress(
      stage,
      completed: done,
      total: total,
      device: json['device'] as String?,
      fallback: json['fallback'] as String?,
      prepareMs: json['prepareMs'] as int?,
      requestMs: json['requestMs'] as int?,
      modelLoadMs: json['modelLoadMs'] as int?,
      modelInferenceMs: json['modelInferenceMs'] as int?,
      colorMs: json['colorMs'] as int?,
    );
  }

  double? get fraction => completed != null && total != null && total! > 0
      ? completed! / total!
      : null;
  String get backendLabel => device == 'cuda'
      ? 'CUDA'
      : device == 'gpu'
      ? 'GPU'
      : device == 'cpu'
      ? 'CPU'
      : '';
  String get label => switch (stage) {
    'queued' => '等待 AI 任务',
    'preprocess' => '准备热像数据',
    'starting' => '启动 AI 引擎',
    'preparing' => '准备推理',
    'loading' => '校验并加载模型',
    'blocks' => '模型块 $completed/$total',
    'tiles' => '图像分块 $completed/$total',
    'inference' => 'AI 推理中',
    'fallback' => 'GPU 不可用，切换 CPU',
    'readback' => '读取推理结果',
    'coloring' => '生成彩色图像',
    'complete' => 'AI 处理完成',
    _ => 'AI 处理中',
  };
}

typedef PhotoAiProgressCallback = void Function(PhotoAiProgress progress);
