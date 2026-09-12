import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/features/settings/settings_page.dart';
import 'package:plai/routes/app_routes.dart';

void main() {
  testWidgets('设置页：出现「课表设置」入口', (WidgetTester tester) async {
    // 高视口让 ListView 一次性构建全部分组项，避免懒加载漏查。
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: SettingsPage())),
    );
    await tester.pumpAndSettle();

    // 「课表设置」分组标题 + 入口 ListTile 各一，共 2。
    expect(find.text('课表设置'), findsNWidgets(2));
    expect(find.text('课表颜色 · 状态色 · 节次时间'), findsOneWidget);

    // AI 分组与入口（S4：AI 服务设置页）。
    expect(find.text('AI 服务'), findsOneWidget);
    expect(find.text('对话模型 · 允许 AI 操作 · OCR'), findsOneWidget);

    // 节次/颜色/样式设置项已迁入新页面，不再出现在设置页。
    expect(find.text('节次时间表'), findsNothing);
    expect(find.text('默认课程颜色'), findsNothing);
    expect(find.text('状态色总开关'), findsNothing);
    expect(find.text('正在上课'), findsNothing);
  });

  testWidgets('设置页：出现「提醒保护」入口并可跳转保活引导',
      (WidgetTester tester) async {
    // 高视口让 ListView 一次性构建全部分组项，避免懒加载漏查。
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 捕获命名路由跳转，无需真实注册页面。
    final List<String?> pushedRoutes = <String?>[];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: const SettingsPage(),
          onGenerateRoute: (RouteSettings settings) {
            pushedRoutes.add(settings.name);
            return MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => const Scaffold(body: Text('stub')),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 入口存在（标题 + 副标题）。
    expect(find.text('提醒保护'), findsOneWidget);
    expect(find.text('检测系统设置，确保提醒准时到达'), findsOneWidget);

    // 「提醒诊断」入口已并入提醒保护页，设置页不再出现。
    expect(find.text('提醒诊断'), findsNothing);

    // 点击 → push 到保活引导路由（提醒保护页）。
    await tester.tap(find.text('提醒保护'));
    await tester.pumpAndSettle();
    expect(pushedRoutes, contains(AppRoutes.keepAliveGuide));
  });

  testWidgets('设置页：震动开关已移除，改为指向系统设置的说明文字',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: SettingsPage())),
    );
    await tester.pumpAndSettle();

    // 震动改由系统通知渠道接管，App 内不再提供开关。
    expect(find.text('课程提醒震动'), findsNothing);
    expect(find.text('日程提醒震动'), findsNothing);
    expect(
      find.text('提醒震动由系统控制：系统设置 → 通知 → Plai → 振动'),
      findsOneWidget,
    );
  });
}
