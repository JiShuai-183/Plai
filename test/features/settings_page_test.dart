import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:plai/features/settings/reminder_settings_page.dart';
import 'package:plai/features/settings/settings_page.dart';
import 'package:plai/features/settings/settings_providers.dart';
import 'package:plai/features/timetable/eams/eams_sync_reminder.dart';
import 'package:plai/services/notifications/keep_alive_checker.dart';
import 'package:plai/services/notifications/notification_providers.dart';

import '../data/test_helpers.dart';

/// 建 in-memory 测试库 —— **必须用 `databaseFactoryFfiNoIsolate`**。
///
/// `TestData.create()` 用默认的 `databaseFactoryFfi`（SQLite 跑在后台 isolate，
/// 真实异步 I/O），在 `testWidgets` 的假时钟 zone 下 Future 永不完成、用例挂死。
/// `databaseFactoryFfiNoIsolate` 同进程执行，假时钟下正常。
Future<TestData> _createTestDataInProcess() async {
  sqfliteFfiInit();
  final AppDatabase db = AppDatabase(
    factory: databaseFactoryFfiNoIsolate,
    path: inMemoryDatabasePath,
  );
  await db.database; // 触发 onCreate 迁移
  return TestData(
    db,
    TimetableRepository(db),
    TaskRepository(db),
    SettingsRepository(db),
  );
}

/// 取「课表同步提醒」开关当前显示值（提醒设置页）。
bool _eamsSwitchValue(WidgetTester tester) => tester
    .widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '课表同步提醒'),
    )
    .value;

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

  // -------------------------------------------------- 提醒设置入口（迁页收敛）

  testWidgets('设置页：「提醒设置」入口存在且副标题正确', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: SettingsPage())),
    );
    await tester.pumpAndSettle();

    // 「提醒」分组标题 + 入口各一。
    expect(find.text('提醒'), findsOneWidget);
    expect(find.text('提醒设置'), findsOneWidget);
    expect(find.text('通知开关 · 提前量 · 提示音 · 提醒保护'), findsOneWidget);
    expect(find.byIcon(Icons.notifications_outlined), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsWidgets);
  });

  testWidgets('设置页：点「提醒设置」→ 落到 ReminderSettingsPage',
      (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());

    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          settingsRepositoryProvider.overrideWithValue(data.settings),
        ],
        child: MaterialApp(
          home: const SettingsPage(),
          onGenerateRoute: (RouteSettings settings) {
            return MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => const ReminderSettingsPage(),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('提醒设置'));
    await tester.pumpAndSettle();

    expect(find.byType(ReminderSettingsPage), findsOneWidget);
  });

  testWidgets('设置页：不再直接显示提醒 7 项与震动说明小字',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: SettingsPage())),
    );
    await tester.pumpAndSettle();

    // 已收敛为单一入口：7 项与小字均不再出现在设置页。
    for (final String label in const <String>[
      '通知提醒',
      '课表同步提醒',
      '课表提醒',
      '日程提醒',
      '上课提醒提前量',
      '日程完成提示音',
      '提醒保护',
      '提醒震动由系统控制：系统设置 → 通知 → Plai → 振动',
    ]) {
      expect(find.text(label), findsNothing, reason: '「$label」应已迁入提醒设置页');
    }

    // 旧的震动开关依旧不存在（改由系统通知渠道接管）。
    expect(find.text('课程提醒震动'), findsNothing);
    expect(find.text('日程提醒震动'), findsNothing);
  });

  testWidgets('设置页：窄屏 + 大字体不溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2.0),
              ),
              child: const SettingsPage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('提醒设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ------- 迁页回归守卫：原设置页用例的语义，新页测试文件未覆盖 -------
  // 这两条断言只此一处，为免静默丢覆盖，暂寄于本文件（指向已迁入的
  // ReminderSettingsPage）。若后续在 reminder_settings_page_test.dart 补齐，
  // 可移走。

  testWidgets('提醒设置页：打开系统设置失败 → 报错气泡告知手动进入',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 原生未确认打开（返回非 'opened'）→ openSettings 返回 false。
    final KeepAliveChecker checker = KeepAliveChecker(
      channelCaller: (String method, Map<String, Object?> args) async => null,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          keepAliveCheckerProvider.overrideWithValue(checker),
        ],
        child: const MaterialApp(home: ReminderSettingsPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('课表提醒'));
    // 气泡由 AnimationController 驱动：用 pump 而非 pumpAndSettle，
    // 否则动画跑完气泡已消失。两次 pump 让 openSettings 的 Future 落地并弹出。
    await tester.pump();
    await tester.pump();

    expect(find.text('无法打开系统设置页，请手动进入系统设置'), findsOneWidget);
  });

  testWidgets('提醒设置页：关闭课表同步提醒不清理另三个键',
      (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());
    await data.settings.setValue(EamsSyncKeys.enabled, '1');
    await data.settings.setValue(EamsSyncKeys.lastAt, '111');
    await data.settings.setValue(EamsSyncKeys.lastSemesterId, '7');
    await data.settings.setValue(EamsSyncKeys.nextRemindAt, '999');

    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          settingsRepositoryProvider.overrideWithValue(data.settings),
        ],
        child: const MaterialApp(home: ReminderSettingsPage()),
      ),
    );
    await tester.pumpAndSettle();

    // 关（'1' → '0'）。
    await tester.tap(find.widgetWithText(SwitchListTile, '课表同步提醒'));
    await tester.pumpAndSettle();
    expect(_eamsSwitchValue(tester), isFalse);

    expect(await data.settings.getValue(EamsSyncKeys.enabled), '0');
    // 三个节流 / 打点键原值不变（由提醒逻辑自管，设置页不动）。
    expect(await data.settings.getValue(EamsSyncKeys.lastAt), '111');
    expect(await data.settings.getValue(EamsSyncKeys.lastSemesterId), '7');
    expect(await data.settings.getValue(EamsSyncKeys.nextRemindAt), '999');
  });
}
