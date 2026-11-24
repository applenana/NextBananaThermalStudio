import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'photo_ai_runtime.dart';

const aiManifestName = 'photo-ai-windows-x64.json';
const aiRepository = 'https://github.com/applenana/NextBananaThermalStudio';
const _gib = 1024 * 1024 * 1024;

class AiRuntimePart {
  const AiRuntimePart(this.name, this.size, this.hash);
  final String name, hash;
  final int size;
}

class AiRuntimePackage {
  AiRuntimePackage(this.tag, this.expandedBytes, this.fileCount, this.parts);
  final String tag;
  final int expandedBytes, fileCount;
  final List<AiRuntimePart> parts;
  int get downloadBytes => parts.fold(0, (n, part) => n + part.size);
  // Parts + assembled ZIP + extracted runtime coexist until validation.
  int get requiredBytes => downloadBytes * 2 + expandedBytes + _gib;

  static AiRuntimePackage parse(
    List<int> bytes,
    String expectedHash,
    String tag,
  ) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedHash) ||
        sha256.convert(bytes).toString() != expectedHash) {
      throw const FormatException('AI 运行包清单 SHA-256 校验失败');
    }
    final json = jsonDecode(utf8.decode(bytes)) as Map;
    if (json['schema'] != 1 ||
        json['runtime'] != 'thermal-pft-v1' ||
        json['platform'] != 'windows-x64' ||
        json['backend'] != 'cuda128' ||
        json['tag'] != tag ||
        !RegExp(r'^v\d+\.\d+\.\d+(\.\d+)?$').hasMatch(tag)) {
      throw const FormatException('AI 运行包与当前应用不兼容');
    }
    final expanded = json['expandedBytes'];
    final count = json['fileCount'];
    final rawParts = json['parts'];
    if (expanded is! int ||
        expanded <= 0 ||
        expanded > 30 * _gib ||
        count is! int ||
        count <= 0 ||
        count > 100000 ||
        rawParts is! List ||
        rawParts.isEmpty ||
        rawParts.length > 32) {
      throw const FormatException('AI 运行包大小或文件清单无效');
    }
    final parts = <AiRuntimePart>[];
    for (var i = 0; i < rawParts.length; i++) {
      final item = rawParts[i] as Map;
      final expected =
          'photo-ai-windows-x64.zip.${(i + 1).toString().padLeft(3, '0')}';
      if (item['name'] != expected ||
          item['size'] is! int ||
          (item['size'] as int) <= 0 ||
          (item['size'] as int) > _gib ||
          item['sha256'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(item['sha256'] as String)) {
        throw const FormatException('AI 运行包分卷清单无效');
      }
      parts.add(
        AiRuntimePart(expected, item['size'] as int, item['sha256'] as String),
      );
    }
    return AiRuntimePackage(tag, expanded, count, List.unmodifiable(parts));
  }
}

/// Reject traversal, Windows ADS/device names and links before writing any file.
String aiArchiveDestination(String root, String name) {
  final pieces = name.replaceAll('\\', '/').split('/');
  final reserved = RegExp(
    r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])($|\.)',
    caseSensitive: false,
  );
  if (pieces.any(
    (s) =>
        s.isEmpty ||
        s == '.' ||
        s == '..' ||
        s.endsWith('.') ||
        s.endsWith(' ') ||
        reserved.hasMatch(s) ||
        RegExp(r'[\x00-\x1f:<>"|?*]').hasMatch(s),
  )) {
    throw FormatException('不安全的运行包路径：$name');
  }
  final target = p.joinAll([root, ...pieces]);
  if (!p.isWithin(p.absolute(root), p.absolute(target))) {
    throw const FormatException('运行包路径超出安装目录');
  }
  return target;
}

void extractAiRuntime(String zip, String destination, int expanded, int count) {
  final input = InputFileStream(zip);
  try {
    final decoder = ZipDecoder();
    final archive = decoder.decodeStream(input);
    final headerNames = <String>{};
    for (final header in decoder.directory.fileHeaders) {
      if (!headerNames.add(header.filename.toLowerCase()) ||
          header.file?.filename != header.filename) {
        throw const FormatException('运行包包含重复或不一致的文件名');
      }
      // archive 4.0.9 reads streaming ZIP64 data descriptors as 32-bit sizes.
      // Its central directory and compressed stream offsets are correct: use
      // the authoritative ZIP64 central-directory size instead.
      final entry = archive.find(header.filename)!;
      entry.size = header.uncompressedSize;
    }
    var total = 0, files = 0;
    final seen = <String>{};
    // Validate the whole directory before extraction. Archives are additionally
    // authenticated by the app-pinned manifest and each part's SHA-256.
    for (final entry in archive) {
      final name = entry.isDirectory
          ? entry.name.replaceFirst(RegExp(r'[/\\]$'), '')
          : entry.name;
      final path = aiArchiveDestination(destination, name);
      if (entry.isSymbolicLink || !seen.add(path.toLowerCase())) {
        throw const FormatException('运行包包含链接或重复路径');
      }
      if (entry.isFile) {
        total += entry.size;
        files++;
      }
    }
    if (total != expanded || files != count) {
      throw const FormatException('运行包解压大小或文件数量不符');
    }
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final target = File(aiArchiveDestination(destination, entry.name));
      target.parent.createSync(recursive: true);
      final output = OutputFileStream(target.path);
      try {
        entry.writeContent(output);
      } finally {
        output.closeSync();
      }
      if (target.lengthSync() != entry.size) {
        throw const FormatException('解压文件大小不符');
      }
    }
  } finally {
    input.closeSync();
  }
}

class AiInstallState {
  const AiInstallState(
    this.message, {
    this.progress,
    this.busy = false,
    this.cancellable = false,
    this.error = false,
  });
  final String message;
  final double? progress;
  final bool busy, cancellable, error;
}

class AiInstallEnvironment {
  const AiInstallEnvironment(this.ramBytes, this.freeBytes, this.gpu);
  final int ramBytes, freeBytes;
  final String gpu;
}

class AiRuntimeInstaller {
  AiRuntimeInstaller._()
    : _version = releaseVersion,
      _digest = manifestHash,
      _rootPath = PhotoAiRuntime.managedRoot,
      _environmentOverride = null,
      _processOverride = null,
      _urlOverride = null;

  @visibleForTesting
  AiRuntimeInstaller.forTesting({
    required String rootPath,
    required String version,
    required String digest,
    required Future<AiInstallEnvironment> Function() environment,
    required Future<ProcessResult> Function(String, List<String>, Duration)
    process,
    required Uri Function(String) url,
  }) : _rootPath = rootPath,
       _version = version,
       _digest = digest,
       _environmentOverride = environment,
       _processOverride = process,
       _urlOverride = url;

  final String _version, _digest, _rootPath;
  final Future<AiInstallEnvironment> Function()? _environmentOverride;
  final Future<ProcessResult> Function(String, List<String>, Duration)?
  _processOverride;
  final Uri Function(String)? _urlOverride;
  bool _installing = false;
  static final instance = AiRuntimeInstaller._();
  static const releaseVersion = String.fromEnvironment('APP_RELEASE_VERSION');
  static const manifestHash = String.fromEnvironment(
    'AI_RUNTIME_MANIFEST_SHA256',
  );
  static bool get supported =>
      Platform.isWindows &&
      Abi.current() == Abi.windowsX64 &&
      Platform.environment['LOCALAPPDATA']?.isNotEmpty == true;
  static bool get configured =>
      releaseVersion.isNotEmpty && manifestHash.isNotEmpty;
  final state = ValueNotifier(const AiInstallState('尚未安装 AI 运行包'));
  AiRuntimePackage? package;
  AiInstallEnvironment? environment;
  bool _cancelled = false;
  HttpClient? _client;
  Future<void>? _checking;

  void _report(
    String message, {
    double? progress,
    bool busy = true,
    bool cancellable = false,
    bool error = false,
  }) => state.value = AiInstallState(
    message,
    progress: progress,
    busy: busy,
    cancellable: cancellable,
    error: error,
  );

  static Future<ProcessResult> _run(
    String executable,
    List<String> args,
    Duration timeout,
  ) async {
    final process = await Process.start(executable, args, runInShell: false);
    final output = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final errors = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    try {
      final results = await Future.wait<Object>([
        process.exitCode,
        output,
        errors,
      ]).timeout(timeout);
      return ProcessResult(
        process.pid,
        results[0] as int,
        results[1],
        results[2],
      );
    } finally {
      process.kill();
    }
  }

  Future<AiInstallEnvironment> _environment() async {
    if (_environmentOverride != null) return _environmentOverride();
    if (!supported) throw StateError('AI 运行包支持 Windows 10/11 x64');
    // Fixed script; no user data or paths are evaluated as shell source.
    const script = r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$os = Get-CimInstance Win32_OperatingSystem
if ([int]$os.BuildNumber -lt 10240) { throw 'Requires Windows 10 or later' }
$drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($env:LOCALAPPDATA))
$gpu = (Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name) -join ', '
@{ramBytes=([long]$os.TotalVisibleMemorySize * 1024);freeBytes=$drive.AvailableFreeSpace;gpu=$gpu} | ConvertTo-Json -Compress
''';
    final encoded = base64Encode(
      script.codeUnits.expand((v) => [v & 255, v >> 8]).toList(),
    );
    final result = await _run(
      '${Platform.environment['SystemRoot']}/System32/WindowsPowerShell/v1.0/powershell.exe',
      ['-NoProfile', '-NonInteractive', '-EncodedCommand', encoded],
      const Duration(seconds: 25),
    );
    if (result.exitCode != 0) throw StateError('无法检测系统内存和可用磁盘空间');
    final data = jsonDecode((result.stdout as String).trim()) as Map;
    return AiInstallEnvironment(
      data['ramBytes'] as int,
      data['freeBytes'] as int,
      data['gpu'] as String,
    );
  }

  Uri _url(String name) =>
      _urlOverride?.call(name) ??
      Uri.parse('$aiRepository/releases/download/v$_version/$name');

  Future<HttpClientResponse> _get(HttpClient client, Uri uri) async {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 30));
    request.headers.set(HttpHeaders.userAgentHeader, 'BananaThermalStudio-AI');
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw HttpException('下载失败 HTTP ${response.statusCode}；请稍后重试', uri: uri);
    }
    return response;
  }

  Future<void> check() =>
      _checking ??= _check().whenComplete(() => _checking = null);
  Future<void> _check() async {
    if (state.value.busy) return;
    package = null;
    _report('正在检测环境和运行包…');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      environment = await _environment();
      if (environment!.ramBytes < 8 * _gib) {
        throw StateError('AI 运行包建议至少 8 GiB 内存，当前内存不足');
      }
      final parent = Directory(_rootPath).parent;
      await parent.create(recursive: true);
      final writableProbe = await parent.createTemp('write-check-');
      try {
        await File(
          p.join(writableProbe.path, 'check'),
        ).writeAsString('ok', flush: true);
      } finally {
        await writableProbe.delete(recursive: true);
      }
      if (Platform.environment.containsKey('THERMAL_AI_RUNTIME')) {
        throw StateError('已设置 THERMAL_AI_RUNTIME，请先取消该自定义路径再使用自动安装');
      }
      if (_version.isEmpty || _digest.isEmpty) {
        throw StateError('此构建未配置独立 AI 运行包，请更新到支持按需安装的正式版本');
      }
      final response = await _get(client, _url(aiManifestName));
      final bytes = <int>[];
      await for (final block in response.timeout(const Duration(seconds: 30))) {
        bytes.addAll(block);
        if (bytes.length > 65536) throw const FormatException('运行包清单过大');
      }
      final candidate = AiRuntimePackage.parse(bytes, _digest, 'v$_version');
      if (environment!.freeBytes < candidate.requiredBytes) {
        throw StateError(
          '磁盘空间不足：安装需要 ${formatAiBytes(candidate.requiredBytes)}，当前可用 ${formatAiBytes(environment!.freeBytes)}',
        );
      }
      package = candidate;
      _report('环境检查通过，可以安装 AI 运行包', busy: false);
    } catch (e) {
      _report('检查失败：$e', busy: false, error: true);
    } finally {
      client.close(force: true);
    }
  }

  void cancel() {
    if (!state.value.cancellable) return;
    _cancelled = true;
    _client?.close(force: true);
  }

  Future<bool> install() async {
    final info = package;
    if (_installing || state.value.busy || info == null) return false;
    _installing = true;
    _cancelled = false;
    _report('准备下载…', cancellable: true);
    final root = Directory(_rootPath);
    final parent = root.parent;
    Directory? staging;
    RandomAccessFile? lock;
    var acquired = false;
    var preserveStaging = false;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    _client = client;
    try {
      environment = await _environment();
      if (environment!.freeBytes < info.requiredBytes) {
        throw StateError('可用磁盘空间不足');
      }
      await parent.create(recursive: true);
      lock = await File(
        p.join(parent.path, 'install.lock'),
      ).open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      acquired = true;
      staging = await parent.createTemp('install-');
      final cache = Directory(p.join(parent.path, 'download-$_digest'));
      await cache.create(recursive: true);
      var downloaded = 0;
      for (final part in info.parts) {
        if (_cancelled) throw StateError('下载已取消');
        final file = File(p.join(cache.path, part.name));
        if (!await _validPart(file, part)) {
          final sink = file.openWrite();
          var received = 0;
          var lastReport = DateTime.now();
          try {
            final response = await _get(client, _url(part.name));
            await for (final bytes in response.timeout(
              const Duration(seconds: 60),
            )) {
              if (_cancelled) throw StateError('下载已取消');
              received += bytes.length;
              if (received > part.size) {
                throw const FormatException('下载文件超过声明大小');
              }
              sink.add(bytes);
              // Apply disk backpressure; do not queue a multi-GB response in RAM.
              await sink.flush();
              if (DateTime.now().difference(lastReport).inMilliseconds >= 100) {
                _report(
                  '下载 ${formatAiBytes(downloaded + received)} / ${formatAiBytes(info.downloadBytes)}',
                  progress: (downloaded + received) / info.downloadBytes,
                  cancellable: true,
                );
                lastReport = DateTime.now();
              }
            }
          } finally {
            await sink.close();
          }
          if (_cancelled) throw StateError('下载已取消');
          _report('正在校验 ${part.name}…', cancellable: true);
          if (!await _validPart(file, part)) {
            await file.delete();
            throw const FormatException('AI 运行包分卷 SHA-256 校验失败，请重试');
          }
        }
        downloaded += part.size;
      }
      if (_cancelled) throw StateError('下载已取消');
      _report('下载完成，正在合并、解压运行包…');
      final zip = File(p.join(staging.path, 'runtime.zip'));
      final sink = zip.openWrite();
      try {
        for (final part in info.parts) {
          await sink.addStream(File(p.join(cache.path, part.name)).openRead());
        }
      } finally {
        await sink.close();
      }
      final payload = Directory(p.join(staging.path, 'payload'));
      await payload.create();
      final zipPath = zip.path, payloadPath = payload.path;
      final expanded = info.expandedBytes, count = info.fileCount;
      await Isolate.run(
        () => extractAiRuntime(zipPath, payloadPath, expanded, count),
      );
      if (!PhotoAiRuntime.completeAt(payload.path)) {
        throw StateError('运行包缺少必要文件');
      }
      _report('正在验证 Python、模型权重和试运行，首次可能需要几分钟…');
      final probe = await (_processOverride ?? _run)(
        p.join(payload.path, 'python', 'python.exe'),
        ['-I', p.join(payload.path, 'check_runtime.py')],
        const Duration(minutes: 5),
      );
      if (probe.exitCode != 0) {
        throw StateError(
          '运行包试运行失败（可能缺少 Visual C++ 运行库）：${probe.stderr.toString().substring(0, probe.stderr.toString().length.clamp(0, 1200))}',
        );
      }
      final result = jsonDecode((probe.stdout as String).trim()) as Map;
      if (result['ok'] != true) throw StateError('运行包试运行返回异常');
      await PhotoAiRuntime.shared.close();
      final backup = Directory(p.join(staging.path, 'previous'));
      if (await root.exists()) await root.rename(backup.path);
      try {
        await payload.rename(root.path);
      } catch (_) {
        if (await backup.exists()) {
          try {
            await backup.rename(root.path);
          } catch (_) {
            preserveStaging = true;
            throw StateError('无法恢复原运行包，原文件保留在 ${backup.path}');
          }
        }
        rethrow;
      }
      PhotoAiRuntime.refreshInstallation();
      _report(
        result['cudaAvailable'] == true
            ? 'AI 运行包安装成功，正在检测 CUDA 加速能力。可启用超分。'
            : 'AI 运行包安装成功，将使用 CPU；照片可增强，实时处理可能较慢。',
        busy: false,
      );
      // Failed/cancelled attempts retain verified parts for a subsequent retry.
      try {
        await cache.delete(recursive: true);
      } catch (_) {
        /* cache only */
      }
      return true;
    } catch (e) {
      _report(
        _cancelled ? '下载已取消；已校验分卷会在重试时复用。' : '安装失败：$e',
        busy: false,
        error: !_cancelled,
      );
      return false;
    } finally {
      client.close(force: true);
      _client = null;
      if (staging != null && !preserveStaging) {
        try {
          await staging.delete(recursive: true);
        } catch (_) {
          /* best effort */
        }
      }
      if (acquired) await lock?.unlock();
      await lock?.close();
      _installing = false;
    }
  }

  Future<bool> _validPart(File file, AiRuntimePart part) async =>
      await file.exists() &&
      await file.length() == part.size &&
      (await sha256.bind(file.openRead()).first).toString() == part.hash;
}

String formatAiBytes(int value) => '${(value / _gib).toStringAsFixed(2)} GiB';
