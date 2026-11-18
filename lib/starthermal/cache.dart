import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'protocol.dart' show legacyStarThermalModel;
export 'protocol.dart' show validateCurves;

Future<Directory> starthermalDirectory() async {
  final root = await getApplicationDocumentsDirectory();
  final preferences = await SharedPreferences.getInstance();
  final custom = preferences.getString('photo_download_dir');
  final base = custom != null && custom.isNotEmpty
      ? custom
      : '${root.path}/BananaThermalStudio';
  final target = Directory('$base/raw/StarThermal');
  final legacy = Directory('$base/raw/$legacyStarThermalModel');
  if (!await target.exists() && await legacy.exists()) {
    await legacy.rename(target.path);
  }
  return target.create(recursive: true);
}

Future<void> atomicWrite(File file, List<int> bytes) async {
  await file.parent.create(recursive: true);
  final temp = File(
    '${file.path}.${DateTime.now().microsecondsSinceEpoch}.part',
  );
  try {
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  } finally {
    if (await temp.exists()) await temp.delete();
  }
}

Future<void> saveChecked(File file, Map<String, dynamic> data) async {
  final payload = jsonEncode(data);
  await atomicWrite(
    file,
    utf8.encode(
      jsonEncode({
        'schema': 1,
        'sha256': sha256.convert(utf8.encode(payload)).toString(),
        'payload': payload,
      }),
    ),
  );
}

Future<Map<String, dynamic>> readChecked(File file) async {
  final wrapper = jsonDecode(await file.readAsString()) as Map;
  final payload = wrapper['payload'] as String;
  if (wrapper['schema'] != 1 ||
      sha256.convert(utf8.encode(payload)).toString() != wrapper['sha256']) {
    throw const FormatException('本地缓存校验失败');
  }
  return (jsonDecode(payload) as Map).cast<String, dynamic>();
}

String deviceCacheKey(String serial) =>
    sha256.convert(utf8.encode(serial)).toString().substring(0, 24);
