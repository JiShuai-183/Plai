import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/features/ai/ai_service_settings_page.dart';

void main() {
  testWidgets('AI 服务页：字段齐全，默认值正常渲染', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 无 DB（宿主测试环境）→ 兜底默认值照常渲染。
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AiServiceSettingsPage())),
    );
    await tester.pumpAndSettle();

    // 三个分组与字段。
    expect(find.text('对话 LLM'), findsOneWidget);
    expect(find.text('启用对话模型'), findsOneWidget);
    expect(find.text('Base URL'), findsOneWidget);
    expect(find.text('API 密钥'), findsOneWidget);
    expect(find.text('模型'), findsOneWidget);
    expect(find.text('允许 AI 操作 App'), findsOneWidget);
    expect(find.text('OCR 文字识别'), findsOneWidget);

    // 服务商模板芯片齐全。
    for (final String name in ['DeepSeek', '智谱', '通义', 'Moonshot', 'OpenAI']) {
      expect(find.text(name), findsOneWidget);
    }

    // OCR 默认 llm → 不出现 App Key 输入。
    expect(find.text('OCR App Key'), findsNothing);

    // 隐私说明。
    expect(find.text('对话内容会发送给你配置的第三方服务，请注意保管密钥。'), findsOneWidget);
  });

  testWidgets('AI 服务页：模板一键填充 + OCR 切 provider 显示 App Key',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AiServiceSettingsPage())),
    );
    await tester.pumpAndSettle();

    // 点 DeepSeek 模板 → 自动填 base_url + model。
    await tester.tap(find.text('DeepSeek'));
    await tester.pump();
    final List<TextField> fields =
        tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(
      fields.any((TextField f) =>
          f.controller?.text == 'https://api.deepseek.com/v1'),
      isTrue,
      reason: 'Base URL 应被模板填充为 DeepSeek 地址',
    );
    expect(
      fields.any((TextField f) => f.controller?.text == 'deepseek-chat'),
      isTrue,
      reason: '模型应被模板填充为 deepseek-chat',
    );

    // OCR 切到专用服务 → 出现 App Key 输入。
    await tester.tap(find.text('专用 OCR 服务'));
    await tester.pumpAndSettle();
    expect(find.text('OCR App Key'), findsOneWidget);
  });

  testWidgets('AI 服务页：测试连接前置校验提示', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AiServiceSettingsPage())),
    );
    await tester.pumpAndSettle();

    // 默认未启用 → 先提示启用。
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.text('请先启用「对话模型」再测试'), findsOneWidget);

    // 启用后仍未填 Base URL → 提示填地址。
    await tester.tap(find.text('启用对话模型'));
    await tester.pump();
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.text('请先填写 Base URL'), findsOneWidget);
  });
}
