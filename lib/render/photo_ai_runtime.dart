import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'photo_ai_model.dart';

/// One shared, sequential local worker for both galleries. No network service.
/// Its interpreter and weights live beside the Windows executable.
class PhotoAiRuntime {
  static final shared = PhotoAiRuntime();
  Process? _process;
  StreamIterator<String>? _responses;
  StreamSubscription<String>? _stderr;
  Future<void> _tail = Future.value();
  Timer? _idle;
  String _diagnostic = '';

  static String get root =>
      Platform.environment['THERMAL_AI_RUNTIME'] ??
      '${File(Platform.resolvedExecutable).parent.path}/photo_ai';
  static bool get installed =>
      Platform.isWindows &&
      File('$root/python/python.exe').existsSync() &&
      File('$root/worker.py').existsSync() &&
      File('$root/weights/manifest.json').existsSync();

  static bool available(PhotoAiModel model) {
    if (!model.external) return Platform.isWindows || Platform.isAndroid;
    if (!installed) return false;
    try {
      final manifest =
          jsonDecode(File('$root/weights/manifest.json').readAsStringSync())
              as Map;
      final name = manifest[model.id]?['file'];
      return name is String && File('$root/weights/$name').existsSync();
    } catch (_) {
      return false;
    }
  }

  Future<Float32List> infer(
    PhotoAiModel model,
    Float32List source,
    int w,
    int h,
  ) {
    final result = Completer<Float32List>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await _request(model, source, w, h));
      } catch (e, s) {
        result.completeError(e, s);
      }
    });
    return result.future;
  }

  Future<Float32List> _request(
    PhotoAiModel model,
    Float32List source,
    int w,
    int h,
  ) async {
    _idle?.cancel();
    if (!available(model)) {
      throw StateError('未安装此热像模型运行包；请安装 photo_ai Windows 扩展包');
    }
    if (!model.supports(w, h, model.scales.first) ||
        source.length != w * h ||
        source.any((v) => !v.isFinite || v < 0 || v > 1)) {
      throw const FormatException('热像模型输入无效');
    }
    try {
      if (_process == null) {
        _diagnostic = '';
        _process = await Process.start(
          '$root/python/python.exe',
          ['-u', '$root/worker.py', '--weights', '$root/weights'],
          mode: ProcessStartMode.normal,
          runInShell: false,
        );
        _responses = StreamIterator(
          _process!.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
        );
        _stderr = _process!.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen((text) {
              _diagnostic += text;
              if (_diagnostic.length > 2000) {
                _diagnostic = _diagnostic.substring(_diagnostic.length - 2000);
              }
            });
      }
      final bytes = ByteData(source.length * 4);
      for (var i = 0; i < source.length; i++) {
        bytes.setFloat32(i * 4, source[i], Endian.little);
      }
      _process!.stdin.writeln(
        jsonEncode({
          'model': model.id,
          'width': w,
          'height': h,
          'data': base64Encode(bytes.buffer.asUint8List()),
        }),
      );
      await _process!.stdin.flush();
      if (!await _responses!.moveNext().timeout(const Duration(minutes: 5))) {
        throw StateError('AI 后台进程退出：$_diagnostic');
      }
      final response = jsonDecode(_responses!.current) as Map<String, dynamic>;
      if (response['ok'] != true) {
        throw StateError(response['error']?.toString() ?? 'AI 推理失败');
      }
      final scale = model.scales.first;
      if (response['model'] != model.id ||
          response['scale'] != scale ||
          response['width'] != w * scale ||
          response['height'] != h * scale) {
        throw const FormatException('AI 返回模型或尺寸不符');
      }
      final decoded = base64Decode(response['data'] as String);
      if (decoded.length != w * h * scale * scale * 4) {
        throw const FormatException('AI 返回数据长度不符');
      }
      final data = ByteData.sublistView(decoded);
      final output = Float32List(decoded.length ~/ 4);
      for (var i = 0; i < output.length; i++) {
        output[i] = data.getFloat32(i * 4, Endian.little);
      }
      if (output.any((v) => !v.isFinite || v < 0 || v > 1)) {
        throw const FormatException('AI 返回非有效灰度');
      }
      return output;
    } catch (_) {
      await close();
      rethrow;
    } finally {
      _idle = Timer(const Duration(seconds: 60), () {
        _tail = _tail.then((_) => close());
      });
    }
  }

  /// Call only when no request is running (or to abort a failed request).
  Future<void> close() async {
    _idle?.cancel();
    final process = _process;
    final responses = _responses;
    final stderr = _stderr;
    _process = null;
    _responses = null;
    _stderr = null;
    process?.kill();
    await responses?.cancel();
    await stderr?.cancel();
  }
}
