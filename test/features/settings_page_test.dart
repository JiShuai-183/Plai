import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:plai/features/settings/settings_page.dart';
import 'package:plai/features/settings/settings_providers.dart';
import 'package:plai/features/timetable/eams/eams_sync_reminder.dart';
import 'package:plai/routes/app_routes.dart';
import 'package:plai/services/notifications/keep_alive_checker.dart';
import 'package:plai/services/notifications/notification_ids.dart';
import 'package:plai/services/notifications/notification_providers.dart';

import '../data/test_helpers.dart';

/// 建 in-memory 测试库 —— **必须用 `databaseFactoryFfiNoIsolate`**。
///
/// `TestData.create()` 用默认的 `databaseFactoryFfi`（SQLite 跑在后台 isolate，
/// 真实异步 I/O），在 `testWidgets` 的假时钟 zone 下 Future 永不完成、用例挂死。
/// `databaseFactoryFfiNoIsolate` 同进程执行，假时钟下正常。
/// 见 `test/features/timetable_page_test.dart` 的同类写法。
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

/// 写失败注入仓库：`getValue` 正常走内存表，`setValue` 一律抛错，
/// 用于验证设置页的「写入失败回滚显示值」。
class _ThrowingSettingsRepo implements ISettingsRepository {
  _ThrowingSettingsRepo(this._values);

  final Map<String, String> _values;

  @override
  Future<String?> getValue(String key) async => _values[key];

  @override
  Future<void> setValue(String key, String value) async =>
      throw StateError('boom');

  @override
  Future<void> setAll(Map<String, String> entries) async =>
      throw StateError('boom');

  @override
  Future<Map<String, String>> getAll() async => Map<String, String>.of(_values);

  @override
  Future<void> remove(String key) async => throw StateError('boom');
}

/// 挂载设置页并注入指定设置仓库（其余 provider 与生产一致）。
Future<void> pumpSettingsWithRepo(
  WidgetTester tester,
  ISettingsRepository repo, {
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  tester.view.physicalSize = const Size(800, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[settingsRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        home: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: const SettingsPage(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 取「课表同步提醒」开关当前显示值。
bool eamsSwitchValue(WidgetTester tester) => tester
    .widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '课表同步提醒'),
    )
    .value;

Future<void> tapEamsSwitch(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(SwitchListTile, '课表同步提醒'));
  await tester.pumpAndSettle();
}

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

  // -------------------------------------------------- 课表同步提醒开关

  testWidgets('课表同步提醒：键不存在 → 缺省视为开', (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());

    await pumpSettingsWithRepo(tester, data.settings);

    expect(find.text('课表同步提醒'), findsOneWidget);
    expect(find.text('超过 7 天未同步教务课表时提醒'), findsOneWidget);
    expect(eamsSwitchValue(tester), isTrue);
    // 缺省不写入任何值。
    expect(await data.settings.getValue(EamsSyncKeys.enabled), isNull);
  });

  testWidgets('课表同步提醒：键为 0 → 显示为关', (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());
    await data.settings.setValue(EamsSyncKeys.enabled, '0');

    await pumpSettingsWithRepo(tester, data.settings);

    expect(eamsSwitchValue(tester), isFalse);
  });

  testWidgets('课表同步提醒：切换写入 1 / 0（断言实际写库值）',
      (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());

    await pumpSettingsWithRepo(tester, data.settings);
    expect(eamsSwitchValue(tester), isTrue);

    // 关 → 写 '0'。
    await tapEamsSwitch(tester);
    expect(eamsSwitchValue(tester), isFalse);
    expect(await data.settings.getValue(EamsSyncKeys.enabled), '0');

    // 开 → 写 '1'。
    await tapEamsSwitch(tester);
    expect(eamsSwitchValue(tester), isTrue);
    expect(await data.settings.getValue(EamsSyncKeys.enabled), '1');
  });

  testWidgets('课表同步提醒：写入失败 → 回滚显示值并报错',
      (WidgetTester tester) async {
    final _ThrowingSettingsRepo repo = _ThrowingSettingsRepo(
      <String, String>{},
    );
    await pumpSettingsWithRepo(tester, repo);
    expect(eamsSwitchValue(tester), isTrue);

    await tester.tap(find.widgetWithText(SwitchListTile, '课表同步提醒'));
    // 气泡由 AnimationController 驱动：用 pump 而非 pumpAndSettle，
    // 否则动画跑完气泡已消失。两次 pump 让写失败的 Future 落地并回滚。
    await tester.pump();
    await tester.pump();

    // 回滚到原值（未被留在错的关闭态）。
    expect(eamsSwitchValue(tester), isTrue);
    expect(find.text('保存失败，请稍后重试'), findsOneWidget);
  });

  testWidgets('课表同步提醒：关闭开关不清理另三个键', (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());
    await data.settings.setValue(EamsSyncKeys.enabled, '1');
    await data.settings.setValue(EamsSyncKeys.lastAt, '111');
    await data.settings.setValue(EamsSyncKeys.lastSemesterId, '7');
    await data.settings.setValue(EamsSyncKeys.nextRemindAt, '999');

    await pumpSettingsWithRepo(tester, data.settings);
    await tapEamsSwitch(tester); // 关

    expect(await data.settings.getValue(EamsSyncKeys.enabled), '0');
    // 三个节流 / 打点键原值不变（由提醒逻辑自管，设置页不动）。
    expect(await data.settings.getValue(EamsSyncKeys.lastAt), '111');
    expect(await data.settings.getValue(EamsSyncKeys.lastSemesterId), '7');
    expect(await data.settings.getValue(EamsSyncKeys.nextRemindAt), '999');
  });

  testWidgets('课表同步提醒：窄屏 + 大字体不溢出', (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());

    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          settingsRepositoryProvider.overrideWithValue(data.settings),
        ],
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

    expect(find.text('课表同步提醒'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
