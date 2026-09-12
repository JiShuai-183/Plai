import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/features/settings/settings_page.dart';
import 'package:plai/routes/app_routes.dart';
import 'package:plai/services/notifications/keep_alive_checker.dart';
import 'package:plai/services/notifications/notification_ids.dart';
import 'package:plai/services/notifications/notification_providers.dart';

/// 挂载设置页，并注入「真 KeepAliveChecker + 假通道调用器」：
/// [calls] 记录底层 `openSettings` 的 method / arguments，
/// [respond] 决定原生返回值（`'opened'` 成功 / 其它失败）。
Future<void> pumpSettingsWithChecker(
  WidgetTester tester,
  List<(String, Map<String, Object?>)> calls, {
  Object? respond = 'opened',
}) async {
  tester.view.physicalSize = const Size(800, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final KeepAliveChecker checker = KeepAliveChecker(
    channelCaller: (String method, Map<String, Object?> args) async {
      calls.add((method, args));
      return respond;
    },
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        keepAliveCheckerProvider.overrideWithValue(checker),
      ],
      child: const MaterialApp(home: SettingsPage()),
    ),
  );
  await tester.pumpAndSettle();
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

  testWidgets('设置页：出现「课表提醒」「日程提醒」两个直达系统渠道的入口',
      (WidgetTester tester) async {
    await pumpSettingsWithChecker(
      tester,
      <(String, Map<String, Object?>)>[],
    );

    expect(find.text('课表提醒'), findsOneWidget);
    expect(find.text('日程提醒'), findsOneWidget);
    // 两个入口副标题一致，均点明去处（声音 / 震动）。
    expect(find.text('系统通知设置（声音 / 震动）'), findsNWidgets(2));
  });

  testWidgets('设置页：点「课表提醒」→ openSettings 直达课表渠道',
      (WidgetTester tester) async {
    final List<(String, Map<String, Object?>)> calls =
        <(String, Map<String, Object?>)>[];
    await pumpSettingsWithChecker(tester, calls);

    await tester.tap(find.text('课表提醒'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    expect(calls.single.$1, 'openSettings');
    expect(calls.single.$2['target'], 'notification');
    expect(calls.single.$2['channelId'], NotificationIds.classChannelId);
  });

  testWidgets('设置页：点「日程提醒」→ openSettings 直达日程渠道',
      (WidgetTester tester) async {
    final List<(String, Map<String, Object?>)> calls =
        <(String, Map<String, Object?>)>[];
    await pumpSettingsWithChecker(tester, calls);

    await tester.tap(find.text('日程提醒'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    expect(calls.single.$1, 'openSettings');
    expect(calls.single.$2['target'], 'notification');
    expect(calls.single.$2['channelId'], NotificationIds.taskChannelId);
  });

  testWidgets('设置页：打开系统设置失败 → 报错气泡告知手动进入',
      (WidgetTester tester) async {
    // 原生未确认打开（返回非 'opened'）→ openSettings 返回 false。
    await pumpSettingsWithChecker(
      tester,
      <(String, Map<String, Object?>)>[],
      respond: null,
    );

    await tester.tap(find.text('课表提醒'));
    // 气泡由 AnimationController 驱动：用 pump 而非 pumpAndSettle，
    // 否则动画跑完气泡已消失。两次 pump 让 openSettings 的 Future 落地并弹出。
    await tester.pump();
    await tester.pump();

    expect(find.text('无法打开系统设置页，请手动进入系统设置'), findsOneWidget);
  });
}
