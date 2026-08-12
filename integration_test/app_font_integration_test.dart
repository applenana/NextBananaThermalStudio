import 'package:banana_thermal/ui/app_font.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows enumerates and applies an installed font family', (
    tester,
  ) async {
    final controller = AppFontController.instance;
    final original = controller.selection.value;
    addTearDown(() => controller.selection.value = original);

    final fonts = await controller.listAvailableFonts(refresh: true);
    final systemFonts = fonts
        .where((font) => font.source == AppFontSource.systemFamily)
        .toList();
    expect(systemFonts, isNotEmpty);

    await tester.pumpWidget(
      ValueListenableBuilder<AppFontOption>(
        valueListenable: controller.selection,
        builder: (context, selected, _) => MaterialApp(
          theme: ThemeData(fontFamily: selected.resolvedFamily),
          home: const Scaffold(body: Text('BananaThermal 中文 123.4 °C')),
        ),
      ),
    );

    final candidate = systemFonts.first;
    controller.selection.value = candidate;
    await tester.pumpAndSettle();

    final textContext = tester.element(find.text('BananaThermal 中文 123.4 °C'));
    expect(controller.currentFamily, candidate.family);
    expect(
      Theme.of(textContext).textTheme.bodyMedium?.fontFamily,
      candidate.family,
    );
  });
}
