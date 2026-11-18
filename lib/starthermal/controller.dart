import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'cache.dart';
import 'client.dart';
import 'protocol.dart';
import 'restore.dart';
import 'stream_worker.dart';
import 'temperature_context.dart';

class SavedCbPhoto {
  final String path, id, serial;
  final Map<String, dynamic> metadata;
  SavedCbPhoto(this.path, this.id, this.serial, this.metadata);
  String get stem => path.substring(0, path.length - '.photo.json'.length);
}

class CbGalleryPhoto {
  final SavedCbPhoto saved;
  final Uint8List raw;
  final Float32List temperatures;
  final bool restoredFromCache;
  CbGalleryPhoto(
    this.saved,
    this.raw,
    this.temperatures,
    this.restoredFromCache,
  );
}

class StarThermalController extends ChangeNotifier {
  late final StarThermalClient client;
  final void Function(Map<String, dynamic>) onInfo;
  final void Function(Float32List, double, double, double) onTemperature;
  final LiveCurveSelection _curveSelection = LiveCurveSelection();
  int? liveCurveIndex;
  DateTime? parametersAcquiredAt;
  Completer<void>? _idle;
  final Map<String, CbGalleryPhoto> _gallery = {};
  Future<void> whenIdle() async {
    await _idle?.future;
  }

  bool busy = false, active = false, disposed = false;
  String? error;
  String status = '连接设备';
  Map<String, dynamic> info;
  Map<String, dynamic>? contextSnapshot;
  List<String> photoIds = [];
  Uint8List? latestY16;
  int frames = 0, crcErrors = 0, recoveries = 0;
  double fps = 0, ratio = 0;
  StreamWorker? _worker;
  Timer? _heartbeat;
  DateTime _lastFrame = DateTime.now();
  StarThermalController({
    required this.info,
    required this.onInfo,
    required this.onTemperature,
    required Future<void> Function(String) write,
    required Future<void> Function(int) setBaud,
    required int baud,
  }) {
    client = StarThermalClient(
      write: write,
      setHostBaud: setBaud,
      onStream: (b) => _worker?.feed(b),
      baud: baud,
    );
  }
  String get serial => info['thermalModuleSerialNumber']?.toString() ?? '';
  void _changed() {
    if (!disposed) notifyListeners();
  }

  Future<T> _operation<T>(Future<T> Function() action) async {
    if (busy || disposed) throw StateError('设备忙，请稍候');
    busy = true;
    _idle = Completer<void>();
    error = null;
    _changed();
    try {
      return await action();
    } catch (e) {
      error = e.toString();
      rethrow;
    } finally {
      busy = false;
      _idle?.complete();
      _idle = null;
      _changed();
    }
  }

  Future<void> initialize() => _operation(() async {
    await client.changeBaud(2000000);
    await _refresh();
    await _start();
  });

  Future<void> _readInfo() async {
    info = (await client.request('GetSysInfo')).object;
    if (isStarThermalInfo(info)) info['deviceModel'] = 'StarThermal';
    if (!isStarThermalInfo(info) || serial.isEmpty) {
      throw const FormatException('设备身份无效');
    }
    onInfo(info);
  }

  Future<Map<String, dynamic>> _snapshot() async {
    await _readInfo();
    final root = await starthermalDirectory();
    final key = deviceCacheKey(serial);
    final crc = info['curvesCrc32'];
    if (info['curvesReady'] != true ||
        crc is! String ||
        !RegExp(r'^[0-9A-F]{8}$').hasMatch(crc)) {
      throw DeviceApiError('NOT_READY: 曲线尚未就绪');
    }
    final cache = File('${root.path}/devices/$key/curves-$crc.json');
    Map<String, dynamic> curves;
    Uint8List blob;
    try {
      final stored = await readChecked(cache);
      if (stored['serial'] != serial) throw const FormatException('缓存设备不符');
      curves = (stored['metadata'] as Map).cast<String, dynamic>();
      blob = base64Decode(stored['binary'] as String);
      validateCurves(curves, blob, crc);
    } catch (_) {
      final response = await client.request('GetCurves');
      curves = response.object;
      blob = response.binary;
      validateCurves(curves, blob, crc);
      await saveChecked(cache, {
        'serial': serial,
        'metadata': curves,
        'binary': base64Encode(blob),
      });
    }
    final nuc = await client.request('GetNucData');
    if (nuc.object['width'] != 120 ||
        nuc.object['height'] != 92 ||
        nuc.binary.length != 44160 ||
        nuc.object['layout'] != 'kmap-u16le-then-reference-i16le') {
      throw const FormatException('NUC 格式错误');
    }
    final data = ByteData.sublistView(nuc.binary);
    var sum = 0;
    for (var i = 22080; i < 44160; i += 2) {
      sum += data.getInt16(i, Endian.little);
    }
    if (sum ~/ 11040 != nuc.object['average_reference']) {
      throw const FormatException('NUC 参考均值错误');
    }
    final parameters = (await client.request('GetSensorParams')).object;
    if (parameters['sequence'] != nuc.object['sequence']) {
      throw SessionChanged();
    }
    final settings = (await client.request('GetSettings')).object;
    final snapshot = <String, dynamic>{
      'schema': 1,
      'capturedAt': DateTime.now().toUtc().toIso8601String(),
      'device': info,
      'session_id': client.sessionId,
      'boot_id': client.bootId,
      'average_reference': nuc.object['average_reference'],
      'nuc': nuc.object,
      'nuc_binary': base64Encode(nuc.binary),
      'parameters': parameters,
      'settings': settings['settings'],
      'measurements': settings['measurements'],
      'curves': curves,
      'curves_binary': base64Encode(blob),
    };
    await saveChecked(File('${root.path}/devices/$key/latest.json'), {
      'serial': serial,
      'baud': client.baud,
      'context': snapshot,
    });
    parametersAcquiredAt = DateTime.now();
    contextSnapshot = snapshot;
    return snapshot;
  }

  Future<void> _refresh() async {
    status = '读取设备参数';
    _changed();
    await client.begin();
    try {
      await _snapshot();
    } finally {
      await client.end();
    }
  }

  Future<void> refresh() => _operation(() async {
    final resume = active;
    if (active) await _stop();
    try {
      await _refresh();
    } finally {
      if (resume && !disposed) await _start();
    }
  });
  Future<void> changeBaud(int baud) => _operation(() async {
    final resume = active;
    if (active) await _stop();
    await client.changeBaud(baud);
    if (resume) await _start();
  });
  Future<void> toggleStream() => _operation(() async {
    if (active) {
      await _stop();
    } else {
      recoveries = 0;
      await _refresh();
      await _start();
    }
  });
  Future<void> stopStream() async {
    if (busy || !active) return;
    await _operation(_stop);
  }

  Future<void> _start() async {
    if (disposed) return;
    _worker?.dispose();
    final worker = _worker = StreamWorker();
    final snapshot = contextSnapshot;
    if (snapshot == null) throw StateError('请先获取设备参数');
    final selection = _curveSelection.select(snapshot);
    liveCurveIndex = selection.index;
    await worker.start(selection.curve, selection.context, (frame) {
      if (disposed || !active) return;
      if (frame['error'] != null) {
        error = '${frame['error']}';
        _changed();
        return;
      }
      latestY16 = frame['y16'] as Uint8List;
      frames = frame['frames'] as int;
      crcErrors = frame['errors'] as int;
      fps = frame['fps'] as double;
      ratio = frame['ratio'] as double;
      _lastFrame = DateTime.now();
      onTemperature(
        frame['temperatures'] as Float32List,
        frame['max'] as double,
        frame['min'] as double,
        frame['avg'] as double,
      );
      _changed();
    });

    try {
      await client.once('StartY16Stream BP64');
    } catch (_) {
      worker.dispose();
      rethrow;
    }
    active = true;
    _lastFrame = DateTime.now();
    status = '实时投屏';
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!active || disposed) return;
      unawaited(
        client.write('Y16KeepAlive\n').catchError((Object e) {
          error = '$e';
          _changed();
        }),
      );
      // Automatic shutter calibration can pause output for several seconds.
      if (!busy && DateTime.now().difference(_lastFrame).inSeconds >= 8) {
        unawaited(
          _operation(() async {
            await _stop();
            if (++recoveries > 3) throw StateError('投屏恢复失败，请重新连接');
            await _refresh();
            await _start();
          }).catchError((Object _) {}),
        );
      }
    });
    _changed();
  }

  Future<void> _stop() async {
    _heartbeat?.cancel();
    active = false;
    try {
      await client.stop();
    } finally {
      _worker?.dispose();
      _worker = null;
      status = '投屏已停止';
      _changed();
    }
  }

  Future<List<String>> _list() async {
    final response = await client.request('GetPicList');
    final entries = response.json as List;
    final ids = entries.map((e) => (e as Map)['id'] as String).toList();
    if (ids.any((id) => !RegExp(r'^[0-9A-F]{8}$').hasMatch(id)) ||
        ids.toSet().length != ids.length) {
      throw const FormatException('照片列表格式错误');
    }
    return ids;
  }

  Future<void> refreshList() => _operation(() async {
    if (active) await _stop();
    // An ID can be reused after deletion. Only the current list generation may
    // reuse a resource without asking the device for its complete contents.
    _gallery.clear();
    await client.begin();
    try {
      photoIds = await _list();
      status = '${photoIds.length} 张设备照片';
    } finally {
      await client.end();
    }
  });

  Future<CbGalleryPhoto> fetchGalleryPhoto(String id) async {
    if (!RegExp(r'^[0-9A-F]{8}$').hasMatch(id)) throw ArgumentError('无效照片 ID');
    final cached = _gallery[id];
    if (cached != null) return cached;
    return _operation(() async {
      if (active) await _stop();
      late Map<String, dynamic> snapshot, metadata;
      late Uint8List pixels;
      await client.begin();
      try {
        snapshot = await _snapshot();
        final r = await client.request('GetPicWithID $id');
        metadata = r.object;
        pixels = r.binary;
        if (metadata['id'] != id ||
            metadata['width'] != 120 ||
            metadata['height'] != 90 ||
            metadata['pixel_format'] != 'i16le' ||
            metadata['pixel_domain'] != 'nuc-corrected-pre-stripe' ||
            metadata['curve_index'] is! int ||
            pixels.length != 21600) {
          throw const FormatException('照片格式错误');
        }
      } finally {
        await client.end();
      }
      // Compare the complete validated resource and effective render context.
      // Prefix hashes cannot identify StarThermal files and must never cancel RX.
      final signature = sha256
          .convert(
            utf8.encode(
              jsonEncode({
                'serial': serial,
                'metadata': metadata,
                'pixels': base64Encode(pixels),
                'context': contextValues(snapshot).toList(),
                'curves': snapshot['device']['curvesCrc32'],
              }),
            ),
          )
          .toString();
      final root = await starthermalDirectory();
      final folder = Directory(
        '${root.path}/downloads/${deviceCacheKey(serial)}/cache/$signature',
      );
      final file = File('${folder.path}/$id.photo.json');
      await saveChecked(File('${folder.path}/context.json'), snapshot);
      await saveChecked(file, {
        'serial': serial,
        'metadata': metadata,
        'y16': base64Encode(pixels),
      });
      final photo = SavedCbPhoto(file.path, id, serial, metadata);
      final decodedFile = File('${photo.stem}.decoded.json');
      Float32List? temperatures;
      var diskHit = false;
      try {
        final decoded = await readChecked(decodedFile);
        final values = decoded['centiC'] as List;
        if (decoded['content'] != signature ||
            values.length != 10800 ||
            values.any((v) => v is! int || v < -32768 || v > 32767)) {
          throw const FormatException('温度缓存无效');
        }
        temperatures = Float32List.fromList(
          values.map((v) => (v as int) / 100).toList(),
        );
        diskHit = true;
      } catch (_) {
        final restored = await restoreSaved(photo);
        temperatures = Float32List.fromList(
          restored.centiC.map((v) => v / 100).toList(),
        );
        await saveChecked(decodedFile, {
          'content': signature,
          'centiC': restored.centiC.toList(),
        });
      }
      final result = CbGalleryPhoto(
        photo,
        await file.readAsBytes(),
        temperatures,
        diskHit,
      );
      _gallery[id] = result;
      return result;
    });
  }

  Future<void> deletePhotos(List<String> ids) => _operation(() async {
    if (ids.any((id) => !RegExp(r'^[0-9A-F]{8}$').hasMatch(id))) {
      throw ArgumentError('无效照片 ID');
    }
    final resume = active;
    if (active) await _stop();
    await client.begin();
    try {
      for (final id in ids) {
        final r = await client.request('DeletePicWithID $id');
        if (r.object['id'] != id || r.object['deleted'] is! bool) {
          throw const FormatException('删除响应错误');
        }
        _gallery.remove(id);
      }
      photoIds = await _list();
      status = '删除完成，本地下载保留';
    } finally {
      await client.end();
      if (resume && !disposed) await _start();
    }
  });

  @override
  void dispose() {
    disposed = true;
    active = false;
    _heartbeat?.cancel();
    _worker?.dispose();
    client.close();
    super.dispose();
  }
}

Future<List<SavedCbPhoto>> listSavedPhotos() async {
  final root = await starthermalDirectory();
  final documents = await getApplicationDocumentsDirectory();
  // Keep downloads from the first integration readable, without a third tab.
  final directories = [
    Directory('${root.path}/downloads'),
    Directory(
      '${documents.path}/BananaThermal/$legacyStarThermalModel/downloads',
    ),
    Directory('${root.parent.path}/$legacyStarThermalModel/downloads'),
  ];
  final photos = <SavedCbPhoto>[];
  for (final directory in directories) {
    if (!await directory.exists()) continue;
    await for (final file in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (file is! File || !file.path.endsWith('.photo.json')) continue;
      try {
        final data = await readChecked(file);
        final meta = (data['metadata'] as Map).cast<String, dynamic>();
        photos.add(
          SavedCbPhoto(
            file.path,
            meta['id'] as String,
            data['serial'] as String,
            meta,
          ),
        );
      } catch (_) {
        /* Unverified files never enter the gallery. */
      }
    }
  }
  photos.sort((a, b) => b.path.compareTo(a.path));
  return photos;
}

Future<CbGalleryPhoto> loadSavedGalleryPhoto(String path) async {
  final data = await readChecked(File(path));
  final metadata = (data['metadata'] as Map).cast<String, dynamic>();
  final photo = SavedCbPhoto(
    path,
    metadata['id'] as String,
    data['serial'] as String,
    metadata,
  );
  final restored = await restoreSaved(photo);
  return CbGalleryPhoto(
    photo,
    await File(path).readAsBytes(),
    Float32List.fromList(restored.centiC.map((v) => v / 100).toList()),
    false,
  );
}

Future<RestoredPhoto> restoreSaved(SavedCbPhoto photo) async {
  final data = await readChecked(File(photo.path));
  final snapshot = await readChecked(
    File('${File(photo.path).parent.path}/context.json'),
  );
  if (snapshot['device']['thermalModuleSerialNumber'] != data['serial']) {
    throw const FormatException('照片与参数设备不符');
  }
  final curves = (snapshot['curves'] as Map).cast<String, dynamic>();
  final blob = base64Decode(snapshot['curves_binary'] as String);
  validateCurves(curves, blob, snapshot['device']['curvesCrc32'] as String);
  final index = (data['metadata'] as Map)['curve_index'] as int;
  final far = snapshot['settings']['distance_mode'] == 'far';
  if (index < 0 ||
      index >= curves['node_count'] ||
      curves['nodes'][index][far ? 'far_valid' : 'near_valid'] != true) {
    throw const FormatException('照片对应曲线不可用');
  }
  final offset = index * 2400 + (far ? 1200 : 0);
  final y16 = base64Decode(data['y16'] as String);
  final curve = Uint8List.fromList(blob.sublist(offset, offset + 1200));
  final result = await Isolate.run(() {
    final restored = restorePhoto(y16, curve, snapshot);
    return (restored, img.encodePng(img.decodeBmp(restored.bmp)!));
  });
  final restored = result.$1;
  await atomicWrite(File('${photo.stem}.png'), result.$2);
  await atomicWrite(File('${photo.stem}.bmp'), restored.bmp);
  final csv = StringBuffer('x,y,temperature_c\n');
  for (var i = 0; i < 10800; i++) {
    csv.writeln(
      '${i % 120},${i ~/ 120},${(restored.centiC[i] / 100).toStringAsFixed(2)}',
    );
  }
  await atomicWrite(File('${photo.stem}.csv'), utf8.encode(csv.toString()));
  return restored;
}
