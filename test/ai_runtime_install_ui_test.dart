import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:banana_thermal/render/ai_runtime_install.dart';
import 'package:banana_thermal/ui/ai_runtime_install_ui.dart';

void main() {
  testWidgets('dialog exposes consent; checking cannot start an installation', (
    tester,
  ) async {
    final installer = AiRuntimeInstaller.instance;
    installer.state.value = const AiInstallState('测试环境检查通过');
    installer.environment = const AiInstallEnvironment(
      16 * 1024 * 1024 * 1024,
      50 * 1024 * 1024 * 1024,
      'test GPU',
    );
    installer.package = AiRuntimePackage('v0.5.6.2', 5000, 5, [
      const AiRuntimePart('part', 1000, 'hash'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showAiRuntimeInstaller(context, checked: true),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('下载并安装'), findsOneWidget);
    expect(find.textContaining('下载大小'), findsOneWidget);
    expect(find.textContaining('安装位置'), findsOneWidget);
    expect(installer.state.value.busy, isFalse);
    await tester.tap(find.text('暂不安装'));
    await tester.pumpAndSettle();
    expect(find.text('下载并安装'), findsNothing);
    expect(installer.state.value.busy, isFalse);
    installer.package = null;
  });
}
