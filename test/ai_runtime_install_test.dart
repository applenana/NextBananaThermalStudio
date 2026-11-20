import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:banana_thermal/render/ai_runtime_install.dart';
import 'package:banana_thermal/render/photo_ai_runtime.dart';

void main() {
  const gib = 1024 * 1024 * 1024;
  late Directory temp;
  late HttpServer server;
  late List<int> zip, manifest;
  late String digest;
  late Map<String, List<int>> assets;
  late Map<String, int> requests;
  late AiRuntimeInstaller installer;
  var freeBytes = 50 * gib;
  var probeFails = false;
  var probes = 0;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ai-installer-test-');
    final archive = Archive();
    final files = <String, List<int>>{
      'python/python.exe': [1, 2, 3],
      'worker.py': utf8.encode('# worker'),
      'check_runtime.py': utf8.encode('# probe'),
      'weights/pft_l1.pth': [1],
      'weights/pft_tv.pth': [2],
      'weights/manifest.json': utf8.encode(
        jsonEncode({
          'pft_l1': {'file': 'pft_l1.pth'},
          'pft_tv': {'file': 'pft_tv.pth'},
        }),
      ),
    };
    for (final entry in files.entries) {
      archive.add(ArchiveFile.bytes(entry.key, entry.value));
    }
    zip = ZipEncoder().encode(archive);
    final parts = [
      zip.sublist(0, zip.length ~/ 2),
      zip.sublist(zip.length ~/ 2),
    ];
    assets = {};
    requests = {};
    final meta = <String, Object>{
      'schema': 1,
      'runtime': 'thermal-pft-v1',
      'platform': 'windows-x64',
      'backend': 'cuda128',
      'tag': 'v0.5.6.2',
      'expandedBytes': files.values.fold<int>(
        0,
        (n, bytes) => n + bytes.length,
      ),
      'fileCount': files.length,
      'parts': [
        for (var i = 0; i < parts.length; i++)
          {
            'name':
                'photo-ai-windows-x64.zip.${(i + 1).toString().padLeft(3, '0')}',
            'size': parts[i].length,
            'sha256': sha256.convert(parts[i]).toString(),
          },
      ],
    };
    for (var i = 0; i < parts.length; i++) {
      assets['photo-ai-windows-x64.zip.${(i + 1).toString().padLeft(3, '0')}'] =
          parts[i];
    }
    manifest = utf8.encode(jsonEncode(meta));
    digest = sha256.convert(manifest).toString();
    assets[aiManifestName] = manifest;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final name = request.uri.pathSegments.last;
      requests.update(name, (n) => n + 1, ifAbsent: () => 1);
      final bytes = assets[name];
      if (bytes == null) {
        request.response.statusCode = 404;
      } else {
        request.response.add(bytes);
      }
      await request.response.close();
    });
    freeBytes = 50 * gib;
    probeFails = false;
    probes = 0;
    installer = AiRuntimeInstaller.forTesting(
      rootPath: p.join(temp.path, 'photo_ai_v1'),
      version: '0.5.6.2',
      digest: digest,
      environment: () async =>
          AiInstallEnvironment(16 * gib, freeBytes, 'test GPU'),
      process: (_, _, _) async {
        probes++;
        return ProcessResult(
          1,
          probeFails ? 1 : 0,
          '{"ok":true,"cudaAvailable":false}',
          'probe failed',
        );
      },
      url: (name) => Uri.parse('http://127.0.0.1:${server.port}/$name'),
    );
  });
  tearDown(() async {
    await server.close(force: true);
    await temp.delete(recursive: true);
  });

  test(
    'metadata check never downloads executable parts; install verifies and activates',
    () async {
      await installer.check();
      expect(installer.package, isNotNull);
      expect(requests.keys, [aiManifestName]);
      expect(probes, 0);
      final revision = PhotoAiRuntime.revision.value;
      expect(await installer.install(), isTrue);
      expect(probes, 1);
      expect(
        PhotoAiRuntime.completeAt(p.join(temp.path, 'photo_ai_v1')),
        isTrue,
      );
      expect(PhotoAiRuntime.revision.value, revision + 1);
      expect(installer.state.value.message, contains('CPU'));
      expect(
        Directory(p.join(temp.path, 'download-$digest')).existsSync(),
        isFalse,
      );
    },
  );
  test(
    'corrupted parts cannot execute or replace existing installation',
    () async {
      final old = File(p.join(temp.path, 'photo_ai_v1', 'keep.txt'));
      await old.parent.create(recursive: true);
      await old.writeAsString('previous');
      assets['photo-ai-windows-x64.zip.002'] = List.filled(
        assets['photo-ai-windows-x64.zip.002']!.length,
        0,
      );
      await installer.check();
      expect(await installer.install(), isFalse);
      expect(probes, 0);
      expect(await old.readAsString(), 'previous');
      expect(installer.state.value.message, contains('SHA-256'));
    },
  );
  test(
    'failed smoke test preserves old install; retry reuses verified parts',
    () async {
      final old = File(p.join(temp.path, 'photo_ai_v1', 'keep.txt'));
      await old.parent.create(recursive: true);
      await old.writeAsString('previous');
      await installer.check();
      probeFails = true;
      expect(await installer.install(), isFalse);
      expect(await old.readAsString(), 'previous');
      probeFails = false;
      expect(await installer.install(), isTrue);
      expect(requests['photo-ai-windows-x64.zip.001'], 1);
      expect(requests['photo-ai-windows-x64.zip.002'], 1);
      expect(await old.exists(), isFalse);
    },
  );
  test('low disk space blocks consent and install', () async {
    freeBytes = 1;
    await installer.check();
    expect(installer.package, isNull);
    expect(await installer.install(), isFalse);
    expect(installer.state.value.message, contains('空间不足'));
    expect(requests.keys, [aiManifestName]);
  });
  test(
    'cancel before download does not activate; a later retry succeeds',
    () async {
      await installer.check();
      final future = installer.install();
      installer.cancel();
      expect(await future, isFalse);
      expect(probes, 0);
      expect(installer.state.value.message, contains('取消'));
      expect(await installer.install(), isTrue);
    },
  );
  test(
    'manifest tampering, wrong tag and nonsequential part names are rejected',
    () {
      expect(
        () => AiRuntimePackage.parse([...manifest, 32], digest, 'v0.5.6.2'),
        throwsFormatException,
      );
      expect(
        () => AiRuntimePackage.parse(manifest, digest, 'v0.5.6.3'),
        throwsFormatException,
      );
      final data = jsonDecode(utf8.decode(manifest)) as Map;
      data['parts'][0]['name'] = '../python.exe';
      final changed = utf8.encode(jsonEncode(data));
      expect(
        () => AiRuntimePackage.parse(
          changed,
          sha256.convert(changed).toString(),
          'v0.5.6.2',
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'archive paths reject Windows traversal, absolute paths and device names',
    () {
      for (final name in [
        '../evil',
        r'..\evil',
        '/etc/passwd',
        r'C:\evil',
        'a:x',
        'a/CON.txt',
        'a/../b',
        'a./file',
        'a//b',
      ]) {
        expect(
          () => aiArchiveDestination(temp.path, name),
          throwsFormatException,
          reason: name,
        );
      }
      expect(
        aiArchiveDestination(temp.path, 'python/Lib/a.py'),
        p.join(temp.path, 'python', 'Lib', 'a.py'),
      );
    },
  );
  test(
    'extractor rejects traversal and mismatched uncompressed sizes',
    () async {
      final archive = Archive()..add(ArchiveFile.bytes('../escape', [1]));
      final path = p.join(temp.path, 'bad.zip');
      await File(path).writeAsBytes(ZipEncoder().encode(archive));
      expect(
        () => extractAiRuntime(path, p.join(temp.path, 'out'), 1, 1),
        throwsFormatException,
      );
      await File(path).writeAsBytes(zip);
      expect(
        () => extractAiRuntime(path, p.join(temp.path, 'out'), 1, 1),
        throwsFormatException,
      );
      expect(Directory(p.join(temp.path, 'out')).existsSync(), isFalse);
    },
  );
  test(
    'actual Python streaming ZIP64 parts install through the Dart extractor',
    () async {
      final source = Directory(p.join(temp.path, 'source'));
      await source.create();
      for (final entry in ZipDecoder().decodeBytes(zip)) {
        final file = File(p.join(source.path, entry.name));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.content);
      }
      await File(p.join(source.path, 'engine.py')).writeAsString('# engine');
      final out = p.join(temp.path, 'packed');
      final result = await Process.run('python', [
        '-c',
        'import sys,zipfile; sys.path.insert(0,"tools/photo_ai"); from package_runtime import package; zipfile.ZIP64_LIMIT=0; print(package(sys.argv[1],sys.argv[2],"v0.5.6.2",part_size=200))',
        source.path,
        out,
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final raw = await File(p.join(out, aiManifestName)).readAsBytes();
      final info = AiRuntimePackage.parse(
        raw,
        result.stdout.toString().trim(),
        'v0.5.6.2',
      );
      expect(info.parts.length, greaterThan(1));
      final merged = File(p.join(temp.path, 'merged.zip'));
      final sink = merged.openWrite();
      for (final part in info.parts) {
        final bytes = await File(p.join(out, part.name)).readAsBytes();
        expect(sha256.convert(bytes).toString(), part.hash);
        sink.add(bytes);
      }
      await sink.close();
      final destination = p.join(temp.path, 'from-python');
      extractAiRuntime(
        merged.path,
        destination,
        info.expandedBytes,
        info.fileCount,
      );
      expect(PhotoAiRuntime.completeAt(destination), isTrue);
    },
  );
}
