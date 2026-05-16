/// 图片下载缓存指纹索引.
///
/// 思路: 设备 v1 / v2 / JPEG 三种格式的"前 4 KB 字节"在物理上几乎不可能
/// 跨张重复 (v2-HTPH 的前 4KB 涵盖完整 24×32 热场, v1 整张文件本来就在
/// 4 KB 内, JPEG 的 header+scan 也具备极高熵). 因此把"前 4 KB 字节"做
/// SHA-256 作为图片唯一指纹, 在下载早期阶段即可识别本地是否已缓存,
/// 命中则立即取消剩余传输, 直接从 `<root>/raw/<filename>` 读出.
///
/// 索引文件: `<photo_root>/index.json`. 结构:
/// ```json
/// {
///   "version": 1,
///   "entries": {
///     "<sha256_hex>": { "filename": "20251001.dat", "size": 12345 }
///   }
/// }
/// ```
/// 跨平台 (Windows / macOS / Linux / Android) 通用, 全部走 dart:io File API.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// 单个缓存条目.
class PhotoCacheEntry {
  final String sha256Hex;
  final String filename;
  final int size;

  const PhotoCacheEntry({
    required this.sha256Hex,
    required this.filename,
    required this.size,
  });

  Map<String, dynamic> toJson() => {'filename': filename, 'size': size};

  factory PhotoCacheEntry.fromJson(String hash, Map<String, dynamic> j) =>
      PhotoCacheEntry(
        sha256Hex: hash,
        filename: j['filename']?.toString() ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
      );
}

/// 缓存索引: 单例式按 root 路径持有. 同进程内多次 [open] 同一 root 复用实例.
class PhotoCacheIndex {
  static final Map<String, PhotoCacheIndex> _instances = {};

  final Directory root;
  final Map<String, PhotoCacheEntry> _entries = {};
  bool _loaded = false;

  PhotoCacheIndex._(this.root);

  /// 获取或创建索引实例. 第一次调用会从磁盘加载 index.json (若存在).
  static Future<PhotoCacheIndex> open(Directory root) async {
    final key = p.normalize(root.path);
    var inst = _instances[key];
    if (inst == null) {
      inst = PhotoCacheIndex._(Directory(key));
      _instances[key] = inst;
    }
    if (!inst._loaded) await inst._load();
    return inst;
  }

  File get _indexFile => File(p.join(root.path, 'index.json'));

  Future<void> _load() async {
    _loaded = true;
    try {
      if (!await _indexFile.exists()) return;
      final txt = await _indexFile.readAsString();
      final j = jsonDecode(txt);
      if (j is! Map) return;
      final entries = j['entries'];
      if (entries is! Map) return;
      _entries.clear();
      entries.forEach((k, v) {
        if (k is String && v is Map) {
          _entries[k] =
              PhotoCacheEntry.fromJson(k, v.cast<String, dynamic>());
        }
      });
    } catch (_) {
      // 索引坏了就当空索引, 不影响下载.
    }
  }

  Future<void> _save() async {
    try {
      if (!await root.exists()) await root.create(recursive: true);
      final out = {
        'version': 1,
        'entries': _entries.map((k, v) => MapEntry(k, v.toJson())),
      };
      await _indexFile.writeAsString(jsonEncode(out));
    } catch (_) {
      // 写失败不影响业务.
    }
  }

  /// 计算"前 4 KB 字节"的 sha256 hex.
  static String fingerprint(Uint8List bytes) {
    final n = bytes.length < 4096 ? bytes.length : 4096;
    final head = (n == bytes.length)
        ? bytes
        : Uint8List.sublistView(bytes, 0, n);
    return sha256.convert(head).toString();
  }

  /// 查找指纹对应的缓存条目, 同时校验底层 raw 文件仍存在且大小一致.
  /// 不存在或文件失效返回 null.
  Future<PhotoCacheEntry?> lookup(String shaHex) async {
    final e = _entries[shaHex];
    if (e == null) return null;
    final f = File(p.join(root.path, 'raw', e.filename));
    if (!await f.exists()) {
      _entries.remove(shaHex);
      await _save();
      return null;
    }
    final st = await f.stat();
    if (st.size != e.size) {
      _entries.remove(shaHex);
      await _save();
      return null;
    }
    return e;
  }

  /// 记录新条目. 同 sha 已存在则覆盖 (新 filename).
  Future<void> remember(String shaHex, String filename, int size) async {
    _entries[shaHex] = PhotoCacheEntry(
      sha256Hex: shaHex,
      filename: filename,
      size: size,
    );
    await _save();
  }
}
