import 'ai_super_resolution.dart';
import 'render_pipeline.dart';

/// Source buffers are immutable after publication by AppState. Keep just one
/// rendering so progress/hover/settings-panel rebuilds do not rerender a frame.
class RealtimeRenderCache {
  PhotoRenderInput? _input;
  RenderedFrame? _frame;

  RenderedFrame render(PhotoRenderInput input) {
    final previous = _input;
    if (previous == null ||
        !identical(previous.temperatures, input.temperatures) ||
        !identical(previous.params, input.params) ||
        !identical(previous.visibleRgb, input.visibleRgb) ||
        previous.width != input.width ||
        previous.height != input.height ||
        previous.visibleW != input.visibleW ||
        previous.visibleH != input.visibleH ||
        previous.min != input.min ||
        previous.max != input.max) {
      _frame = input.render();
      _input = input;
    }
    return _frame!;
  }

  void clear() {
    _input = null;
    _frame = null;
  }
}
