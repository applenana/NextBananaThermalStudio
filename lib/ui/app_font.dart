import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String bundledAppFontFamily = 'SmileySans';

enum AppFontSource { bundled, systemDefault, systemFamily, systemFile }

@immutable
class AppFontOption {
  const AppFontOption({
    required this.id,
    required this.label,
    required this.source,
    this.family,
    this.filePath,
  });

  static const bundled = AppFontOption(
    id: 'bundled:$bundledAppFontFamily',
    label: '得意黑（应用默认）',
    source: AppFontSource.bundled,
    family: bundledAppFontFamily,
  );

  static const systemDefault = AppFontOption(
    id: 'system:default',
    label: '系统默认字体',
    source: AppFontSource.systemDefault,
  );

  final String id;
  final String label;
  final AppFontSource source;
  final String? family;
  final String? filePath;

  String? get resolvedFamily {
    if (source == AppFontSource.systemDefault) return null;
    if (source == AppFontSource.systemFile) {
      final path = filePath;
      return path == null ? null : AppFontController.runtimeFamilyFor(path);
    }
    return family;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'source': source.name,
    'family': family,
    'filePath': filePath,
  };

  static AppFontOption? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final label = value['label'];
    final sourceName = value['source'];
    if (id is! String || label is! String || sourceName is! String) {
      return null;
    }
    final source = AppFontSource.values
        .where((candidate) => candidate.name == sourceName)
        .firstOrNull;
    if (source == null) return null;
    final family = value['family'] is String ? value['family'] as String : null;
    final filePath = value['filePath'] is String
        ? value['filePath'] as String
        : null;
    if (source == AppFontSource.systemFamily &&
        (family == null || family.isEmpty)) {
      return null;
    }
    if (source == AppFontSource.systemFile &&
        (filePath == null || filePath.isEmpty)) {
      return null;
    }
    return AppFontOption(
      id: id,
      label: label,
      source: source,
      family: family,
      filePath: filePath,
    );
  }
}

class AppFontController {
  AppFontController._();

  static final AppFontController instance = AppFontController._();
  static const _preferenceKey = 'app_font_selection_v1';
  static const _channel = MethodChannel(
    'com.applenana.banana_thermal/system_fonts',
  );
  static const _maxDynamicFontBytes = 64 * 1024 * 1024;

  final ValueNotifier<AppFontOption> selection = ValueNotifier<AppFontOption>(
    AppFontOption.bundled,
  );
  final Set<String> _loadedRuntimeFamilies = <String>{};
  SharedPreferences? _preferences;
  List<AppFontOption>? _cachedOptions;

  String? get currentFamily => selection.value.resolvedFamily;

  static String runtimeFamilyFor(String path) {
    final digest = sha256.convert(utf8.encode(path)).toString();
    return 'BananaSystemFont_${digest.substring(0, 16)}';
  }

  Future<void> initialize(SharedPreferences preferences) async {
    _preferences = preferences;
    final encoded = preferences.getString(_preferenceKey);
    if (encoded == null || encoded.isEmpty) return;
    try {
      final restored = AppFontOption.fromJson(jsonDecode(encoded));
      if (restored == null) return;
      await _prepare(restored);
      selection.value = restored;
    } catch (_) {
      await preferences.remove(_preferenceKey);
      selection.value = AppFontOption.bundled;
    }
  }

  Future<void> select(AppFontOption option) async {
    await _prepare(option);
    selection.value = option;
    final preferences = _preferences ?? await SharedPreferences.getInstance();
    _preferences = preferences;
    await preferences.setString(_preferenceKey, jsonEncode(option.toJson()));
  }

  Future<void> reset() async {
    selection.value = AppFontOption.bundled;
    final preferences = _preferences ?? await SharedPreferences.getInstance();
    _preferences = preferences;
    await preferences.remove(_preferenceKey);
  }

  Future<List<AppFontOption>> listAvailableFonts({bool refresh = false}) async {
    if (!refresh && _cachedOptions != null) {
      return List.unmodifiable(_cachedOptions!);
    }
    final options = <AppFontOption>[
      AppFontOption.bundled,
      AppFontOption.systemDefault,
    ];
    try {
      final raw = await _channel.invokeListMethod<Object?>('listSystemFonts');
      for (final entry in raw ?? const <Object?>[]) {
        final option = _decodePlatformOption(entry);
        if (option != null) options.add(option);
      }
    } on MissingPluginException {
      // Unsupported platforms still expose the bundled and platform-default
      // choices, so the settings UI remains usable.
    } on PlatformException {
      rethrow;
    }
    final unique = <String, AppFontOption>{};
    for (final option in options) {
      unique.putIfAbsent(option.id, () => option);
    }
    final fixed = unique.values.take(2).toList();
    final system = unique.values.skip(2).toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    _cachedOptions = [...fixed, ...system];
    return List.unmodifiable(_cachedOptions!);
  }

  AppFontOption? _decodePlatformOption(Object? entry) {
    if (entry is String && entry.trim().isNotEmpty) {
      final family = entry.trim();
      return AppFontOption(
        id: 'system-family:$family',
        label: family,
        source: AppFontSource.systemFamily,
        family: family,
      );
    }
    if (entry is! Map) return null;
    final label = entry['label'];
    final family = entry['family'];
    final filePath = entry['path'];
    if (label is! String || label.trim().isEmpty) return null;
    if (filePath is String && filePath.isNotEmpty) {
      return AppFontOption(
        id: 'system-file:$filePath',
        label: label.trim(),
        source: AppFontSource.systemFile,
        filePath: filePath,
      );
    }
    if (family is String && family.isNotEmpty) {
      return AppFontOption(
        id: 'system-family:$family',
        label: label.trim(),
        source: AppFontSource.systemFamily,
        family: family,
      );
    }
    return null;
  }

  Future<void> _prepare(AppFontOption option) async {
    if (option.source != AppFontSource.systemFile) return;
    final path = option.filePath;
    if (path == null || path.isEmpty) {
      throw const FormatException('系统字体路径为空');
    }
    final file = File(path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw FileSystemException('系统字体文件不存在', path);
    }
    if (stat.size <= 0 || stat.size > _maxDynamicFontBytes) {
      throw FileSystemException('系统字体文件大小无效', path);
    }
    final family = runtimeFamilyFor(path);
    if (_loadedRuntimeFamilies.contains(family)) return;
    final bytes = await file.readAsBytes();
    final loader = FontLoader(family)
      ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();
    _loadedRuntimeFamilies.add(family);
  }
}

ValueListenable<AppFontOption> get appFontSelection =>
    AppFontController.instance.selection;

String? get currentAppFontFamily => AppFontController.instance.currentFamily;
