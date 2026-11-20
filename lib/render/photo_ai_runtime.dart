import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'photo_ai_model.dart';
import 'photo_ai_progress.dart';

class PhotoAiCudaCapability {
  final bool available;
  final String detail;
  const PhotoAiCudaCapability(this.available, this.detail);
}

/// One shared, sequential local worker for galleries and live display. No network service.
/// Interpreter and weights live in per-user storage or a legacy portable bundle.
class PhotoAiRuntime {
  static final shared = PhotoAiRuntime();
  static final revision = ValueNotifier<int>(0);

  static String get managedRoot =>
      '${Platform.environment['LOCALAPPDATA'] ?? File(Platform.resolvedExecutable).parent.path}/BananaThermalStudio/ai/photo_ai_v1';

  static bool completeAt(String directory) {
    try {
      if (!File('$directory/python/python.exe').existsSync() ||
          !File('$directory/worker.py').existsSync()) {
        return false;
      }
      final manifest =
          jsonDecode(
                File('$directory/weights/manifest.json').readAsStringSync(),
              )
              as Map;
      return PhotoAiModel.values.every((model) {
        final name = manifest[model.id]?['file'];
        return name is String && File('$directory/weights/$name').existsSync();
      });
    } catch (_) {
      return false;
    }
  }

  static void refreshInstallation() {
    shared._cudaProbe = null;
    shared.cudaCapability = null;
    revision.value++;
  }

  Process? _process;
  StreamIterator<String>? _responses;
  StreamSubscription<String>? _stderr;
  Future<void> _tail = Future.value();
  Timer? _idle;
  String _diagnostic = '';
  Future<PhotoAiCudaCapability>? _cudaProbe;
  PhotoAiCudaCapability? cudaCapability;

  /// Cache one asynchronous probe per app run; never launch Python per frame.
  Future<PhotoAiCudaCapability> checkCuda() => _cudaProbe ??= _probeCuda();

  Future<PhotoAiCudaCapability> _probeCuda() async {
    Process? process;
    try {
      if (!available(PhotoAiModel.pftTv)) {
        return cudaCapability = const PhotoAiCudaCapability(
          false,
          '未安装 Thermal-PFT Windows 扩展包',
        );
      }
      process = await Process.start('$root/python/python.exe', [
        '-u',
        '$root/worker.py',
        '--probe-cuda',
      ], runInShell: false);
      final output = process.stdout.transform(utf8.decoder).join();
      final errors = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final result = await Future.wait<Object>([
        output,
        errors,
        process.exitCode,
      ]).timeout(const Duration(seconds: 45));
      if (result[2] != 0) throw StateError('CUDA 检测进程退出：${result[1]}');
      final response = jsonDecode(result[0] as String) as Map;
      return cudaCapability = PhotoAiCudaCapability(
        response['cudaAvailable'] == true,
        (response['deviceName'] ?? response['reason'] ?? 'CUDA 不可用').toString(),
      );
    } catch (e) {
      return cudaCapability = PhotoAiCudaCapability(false, 'CUDA 检测失败：$e');
    } finally {
      process?.kill();
    }
  }

  static String get root =>
      Platform.environment['THERMAL_AI_RUNTIME'] ??
      (completeAt(managedRoot)
          ? managedRoot
          : '${File(Platform.resolvedExecutable).parent.path}/photo_ai');
  static bool get installed =>
      Platform.isWindows &&
      File('$root/python/python.exe').existsSync() &&
      File('$root/worker.py').existsSync() &&
      File('$root/weights/manifest.json').existsSync();

  static bool available(PhotoAiModel model) {
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
    int h, {
    PhotoAiProgressCallback? onProgress,
  }) {
    onProgress?.call(const PhotoAiProgress('queued'));
    final result = Completer<Float32List>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await _request(model, source, w, h, onProgress));
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
    PhotoAiProgressCallback? onProgress,
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
        onProgress?.call(const PhotoAiProgress('starting'));
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
      // Progress is a separate protocol event; only a final response completes
      // the request. The absolute deadline also bounds a chatty/hung worker.
      final deadline = DateTime.now().add(const Duration(minutes: 5));
      late Map<String, dynamic> response;
      while (true) {
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) throw TimeoutException('AI 处理超时');
        if (!await _responses!.moveNext().timeout(remaining)) {
          throw StateError('AI 后台进程退出：$_diagnostic');
        }
        response = jsonDecode(_responses!.current) as Map<String, dynamic>;
        if (response['event'] != 'progress') break;
        onProgress?.call(PhotoAiProgress.fromJson(response));
      }
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
      onProgress?.call(
        PhotoAiProgress(
          'readback',
          device: response['device'] as String?,
          fallback: response['fallback'] as String?,
          requestMs: response['requestMs'] as int?,
          modelLoadMs: response['loadMs'] as int?,
          modelInferenceMs: response['inferMs'] as int?,
        ),
      );
      return output;
    } catch (_) {
      await close();
      rethrow;
    } finally {
      _idle = Timer(const Duration(minutes: 5), () {
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
