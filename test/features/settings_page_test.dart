import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/features/settings/settings_page.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/features/settings/settings_providers.dart';
import 'package:plai/routes/app_routes.dart';
import 'package:plai/services/notifications/notification_scheduler.dart';

/// 内存版 ISettingsRepository（测试注入）。
class FakeSettingsRepository implements ISettingsRepository {
  FakeSettingsRepository([Map<String, String>? seed])
      : _map = <String, String>{...?seed};

  final Map<String, String> _map;

  @override
  Future<String?> getValue(String key) async => _map[key];

  @override
  Future<void> setValue(String key, String value) async {
    _map[key] = value;
  }

  @override
  Future<void> setAll(Map<String, String> entries) async =>
      _map.addAll(entries);

  @override
  Future<Map<String, String>> getAll() async => Map.of(_map);

  @override
  Future<void> remove(String key) async {
    _map.remove(key);
  }
}

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

  testWidgets('设置页：出现「提醒诊断」入口并可跳转对应路由',
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
    expect(find.text('提醒诊断'), findsOneWidget);
    expect(
      find.text('查看提醒是否已被系统正常调度（排查不响）'),
      findsOneWidget,
    );

    // 点击 → push 到提醒诊断路由。
    await tester.tap(find.text('提醒诊断'));
    await tester.pumpAndSettle();
    expect(pushedRoutes, contains(AppRoutes.notificationDiagnostics));
  });

  testWidgets('设置页：提醒震动开关默认关，切换后写设置键',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final FakeSettingsRepository settings = FakeSettingsRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(settings),
        ],
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();

    // 默认不震动。
    final SwitchListTile classSwitch = tester.widget(find.widgetWithText(
        SwitchListTile, '课程提醒震动')) as SwitchListTile;
    expect(classSwitch.value, isFalse);
    final SwitchListTile taskSwitch = tester.widget(find.widgetWithText(
        SwitchListTile, '日程提醒震动')) as SwitchListTile;
    expect(taskSwitch.value, isFalse);

    // 切换 → 写键。
    await tester.tap(find.text('课程提醒震动'));
    await tester.pumpAndSettle();
    expect(
        await settings.getValue(NotificationSettingsKeys.classVibrate), 'true');
    await tester.tap(find.text('日程提醒震动'));
    await tester.pumpAndSettle();
    expect(
        await settings.getValue(NotificationSettingsKeys.taskVibrate), 'true');
  });
}
