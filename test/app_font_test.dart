import 'dart:convert';

import 'package:banana_thermal/ui/app_font.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.applenana.banana_thermal/system_fonts');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('font selection JSON round-trips system families', () {
    const original = AppFontOption(
      id: 'system-family:Microsoft YaHei UI',
      label: 'Microsoft YaHei UI',
      source: AppFontSource.systemFamily,
      family: 'Microsoft YaHei UI',
    );

    final restored = AppFontOption.fromJson(original.toJson());

    expect(restored?.id, original.id);
    expect(restored?.label, original.label);
    expect(restored?.source, original.source);
    expect(restored?.resolvedFamily, original.family);
  });

  test('runtime font family is stable and path-specific', () {
    final first = AppFontController.runtimeFamilyFor(
      '/system/fonts/Roboto.ttf',
    );
    final second = AppFontController.runtimeFamilyFor(
      '/system/fonts/Roboto.ttf',
    );
    final other = AppFontController.runtimeFamilyFor('/system/fonts/Serif.ttf');

    expect(first, second);
    expect(first, startsWith('BananaSystemFont_'));
    expect(first, isNot(other));
  });

  test('font selection persists and reset restores the bundled font', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final controller = AppFontController.instance;
    await controller.initialize(preferences);
    const selected = AppFontOption(
      id: 'system-family:Microsoft YaHei UI',
      label: 'Microsoft YaHei UI',
      source: AppFontSource.systemFamily,
      family: 'Microsoft YaHei UI',
    );

    await controller.select(selected);

    final encoded = preferences.getString('app_font_selection_v1');
    expect(encoded, isNotNull);
    expect(
      (jsonDecode(encoded!) as Map<String, Object?>)['family'],
      selected.family,
    );
    expect(controller.selection.value.id, selected.id);

    await controller.reset();
    expect(controller.selection.value, AppFontOption.bundled);
    expect(preferences.containsKey('app_font_selection_v1'), isFalse);
  });

  test('platform font list is deduplicated and sorted', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'listSystemFonts');
          return <Object?>[
            <String, String>{'label': 'Zulu', 'family': 'Zulu'},
            <String, String>{'label': 'alpha', 'family': 'alpha'},
            <String, String>{'label': 'Zulu duplicate', 'family': 'Zulu'},
            <String, String>{
              'label': 'Roboto',
              'path': '/system/fonts/Roboto-Regular.ttf',
            },
          ];
        });

    final options = await AppFontController.instance.listAvailableFonts(
      refresh: true,
    );

    expect(options.take(2).map((font) => font.id), [
      AppFontOption.bundled.id,
      AppFontOption.systemDefault.id,
    ]);
    expect(options.skip(2).map((font) => font.label), [
      'alpha',
      'Roboto',
      'Zulu',
    ]);
  });
}
