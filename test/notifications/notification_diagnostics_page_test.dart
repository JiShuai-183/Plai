import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/services/notifications/notification_diagnostics.dart';
import 'package:plai/services/notifications/notification_diagnostics_page.dart';

NotificationDiagnostics fake({
  bool? notificationsEnabled = true,
  bool? exactAlarmsAllowed = true,
  bool remindersEnabled = true,
  int pendingClassCount = 3,
  int pendingTaskCount = 2,
  int pendingOtherCount = 0,
  DateTime? lastRescheduleAt,
  String? lastRescheduleResult = 'ok',
  int? lastRescheduleCount = 5,
  int degradedScheduleCount = 0,
  String osVersion = 'Android 13 (API 33)',
}) =>
    NotificationDiagnostics(
      notificationsEnabled: notificationsEnabled,
      exactAlarmsAllowed: exactAlarmsAllowed,
      remindersEnabled: remindersEnabled,
      pendingClassCount: pendingClassCount,
      pendingTaskCount: pendingTaskCount,
      pendingOtherCount: pendingOtherCount,
      lastRescheduleAt: lastRescheduleAt,
      lastRescheduleResult: lastRescheduleResult,
      lastRescheduleCount: lastRescheduleCount,
      degradedScheduleCount: degradedScheduleCount,
      osVersion: osVersion,
    );

Widget harness(NotificationDiagnostics d) => ProviderScope(
      overrides: [
        notificationDiagnosticsProvider.overrideWith((ref) async => d),
      ],
      child: const MaterialApp(home: NotificationDiagnosticsPage()),
    );

void main() {
  testWidgets('渲染关键行：待触发计数 / 上次重排 / 系统版本', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(fake(
      lastRescheduleAt: DateTime.now().subtract(const Duration(minutes: 3)),
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('上课提醒 3 条 · 日程提醒 2 条'), findsOneWidget);
    expect(find.textContaining('成功 · 排了 5 条'), findsOneWidget);
    expect(find.text('Android 13 (API 33)'), findsOneWidget);
    // 三项权限正常。
    expect(find.text('正常'), findsNWidgets(3));
  });

  testWidgets('0 条待触发 → 醒目提示', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(fake(
      pendingClassCount: 0,
      pendingTaskCount: 0,
      lastRescheduleAt: null,
      lastRescheduleResult: null,
      lastRescheduleCount: null,
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('上课提醒 0 条 · 日程提醒 0 条'), findsOneWidget);
    expect(find.textContaining('系统里没有任何待触发的提醒'), findsOneWidget);
    expect(find.text('暂无记录'), findsOneWidget);
  });

  testWidgets('权限异常 + 降级 >0 → 显示后果说明与醒目提示',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(fake(
      notificationsEnabled: false,
      exactAlarmsAllowed: false,
      degradedScheduleCount: 2,
    )));
    await tester.pumpAndSettle();

    expect(find.text('异常'), findsNWidgets(2));
    expect(find.textContaining('提醒一定不响'), findsOneWidget);
    expect(find.textContaining('只能非精确调度'), findsWidgets);
    expect(find.textContaining('2 条提醒只能非精确调度'), findsOneWidget);
  });

  testWidgets('复制诊断信息 → 气泡反馈（用 pump，不用 pumpAndSettle）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 剪贴板走 SystemChannels.platform，测试宿主需注册 mock，否则抛
    // MissingPluginException 而走失败气泡。
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async => null,
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(harness(fake()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('复制诊断信息'));
    // 气泡由 AnimationController 驱动：pumpAndSettle 会把动画跑完导致气泡消失，
    // 只 pump 让异步链路（Clipboard → 插入 Overlay）完成即可。
    await tester.pump();
    await tester.pump();

    expect(find.text('诊断信息已复制'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 收尾：跑完动画，避免残留计时器。
    await tester.pumpAndSettle();
  });
}
