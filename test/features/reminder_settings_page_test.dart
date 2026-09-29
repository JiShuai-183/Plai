import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show AndroidFlutterLocalNotificationsPlugin;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:plai/features/settings/reminder_settings_page.dart';
import 'package:plai/features/settings/settings_providers.dart';
import 'package:plai/features/timetable/eams/eams_sync_reminder.dart';
import 'package:plai/routes/app_routes.dart';
import 'package:plai/services/notifications/class_reminder_planner.dart';
import 'package:plai/services/notifications/keep_alive_checker.dart';
import 'package:plai/services/notifications/notification_ids.dart';
import 'package:plai/services/notifications/notification_providers.dart';
import 'package:plai/services/notifications/notification_scheduler.dart';

import '../data/test_helpers.dart';

/// 建 in-memory 测试库 —— **必须用 `databaseFactoryFfiNoIsolate`**。
///
/// `TestData.create()` 用默认的 `databaseFactoryFfi`（SQLite 跑在后台 isolate，
/// 真实异步 I/O），在 `testWidgets` 的假时钟 zone 下 Future 永不完成、用例挂死。
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
/// 用于验证「写入失败回滚显示值」。
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

/// 假提醒调度器：不触通知插件；记录重排 / 取消调用；可注入引导判定与抛错。
class _FakeScheduler extends NotificationScheduler {
  _FakeScheduler({
    this.showGuide = false,
    this.throwOnReschedule = false,
    this.throwOnCancel = false,
  }) : super(
          TimetableRepository(AppDatabase.instance),
          TaskRepository(AppDatabase.instance),
          SettingsRepository(AppDatabase.instance),
        );

  final bool showGuide;
  final bool throwOnReschedule;
  final bool throwOnCancel;

  int rescheduleCalls = 0;
  int cancelCalls = 0;

  @override
  Future<bool> shouldShowKeepAliveGuide() async => showGuide;

  @override
  Future<void> rescheduleAll({List<ClassReminderPlan>? classPlans}) async {
    rescheduleCalls++;
    if (throwOnReschedule) throw StateError('boom');
  }

  @override
  Future<void> cancelAll() async {
    cancelCalls++;
    if (throwOnCancel) throw StateError('boom');
  }
}

/// 挂载提醒设置页并注入设置仓库 + 假调度器（其余 provider 与生产一致）。
Future<void> _pumpPage(
  WidgetTester tester,
  ISettingsRepository repo, {
  NotificationScheduler? scheduler,
  Size size = const Size(800, 2000),
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        settingsRepositoryProvider.overrideWithValue(repo),
        notificationSchedulerProvider.overrideWithValue(
          scheduler ?? _FakeScheduler(),
        ),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: const ReminderSettingsPage(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 取「课表同步提醒」开关当前显示值。
bool _eamsSwitchValue(WidgetTester tester) => tester
    .widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '课表同步提醒'),
    )
    .value;

/// 取「通知提醒」开关当前显示值。
bool _notifSwitchValue(WidgetTester tester) => tester
    .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '通知提醒'))
    .value;

Future<void> _tapTile(WidgetTester tester, String text) async {
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

/// 挂载提醒设置页，注入「真 KeepAliveChecker + 假通道调用器」：
/// [calls] 记录底层 `openSettings` 的 method / arguments；
/// [respond] 为通道返回的原生结果（默认 `'opened'`；传 `null` 模拟原生未确认
/// 打开，使 `openSettings` 返回 false，用以覆盖失败分支）。
Future<void> _pumpWithChecker(
  WidgetTester tester,
  List<(String, Map<String, Object?>)> calls, {
  String? respond = 'opened',
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
        notificationSchedulerProvider.overrideWithValue(_FakeScheduler()),
      ],
      child: const MaterialApp(home: ReminderSettingsPage()),
    ),
  );
  await tester.pumpAndSettle();
}

/// flutter_local_notifications 的 Android method channel 名（插件源码常量）。
const MethodChannel _flnChannel = MethodChannel(
  'dexterous.com/flutter/local_notifications',
);

/// mock 通知插件的 Android 通道，记录被调用的 method 名。
void _mockNotificationChannel(List<String> calls) {
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_flnChannel, (MethodCall call) async {
    calls.add(call.method);
    return true;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(_flnChannel, null));
}

/// 在需要走 Android 权限分支的用例里包住测试体：
/// - 注册插件平台实例（测试环境从未 `registerWith`，`requestPermissions` 会因
///   `FlutterLocalNotificationsPlatform.instance` 未初始化而抛 LateError）；
/// - 置 Android 平台，让 `resolvePlatformSpecificImplementation` 解析出 Android 实现，
///   从而真正走 method channel（被 [_mockNotificationChannel] 拦截）；
/// - `debugDefaultTargetPlatformOverride` 必须在**测试体结束前**复位 ——
///   flutter_test 的 invariant 校验就在测试体结束时跑，`tearDown` / `addTearDown`
///   都太晚，会报「foundation debug variable was changed」。
Future<void> _withAndroidPlatform(Future<void> Function() body) async {
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  // ------------------------------------------------------------- 结构

  testWidgets('提醒设置页：7 项 + 三个分组标题全部渲染', (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());

    await _pumpPage(tester, data.settings);

    // AppBar 标题。
    expect(find.text('提醒设置'), findsOneWidget);

    // 三个分组标题。
    expect(find.text('通知'), findsOneWidget);
    expect(find.text('课表'), findsOneWidget);
    expect(find.text('日程'), findsOneWidget);

    // 7 项。
    expect(find.text('通知提醒'), findsOneWidget);
    expect(
      find.text('提醒震动由系统控制：系统设置 → 通知 → Plai → 振动'),
      findsOneWidget,
    );
    expect(find.text('提醒保护'), findsOneWidget);
    expect(find.text('上课提醒提前量'), findsOneWidget);
    expect(find.text('课表同步提醒'), findsOneWidget);
    expect(find.text('课表提醒'), findsOneWidget);
    expect(find.text('日程提醒'), findsOneWidget);
    expect(find.text('日程完成提示音'), findsOneWidget);
    // 两个渠道入口副标题一致。
    expect(find.text('系统通知设置（声音 / 震动）'), findsNWidgets(2));

    // 「提醒诊断」入口已并入提醒保护页，提醒设置页不再出现独立条目。
    expect(find.text('提醒诊断'), findsNothing);
  });

  // ------------------------------------------------------- 通知总开关

  testWidgets('通知开关：开 → 申请权限 + 全量重排', (WidgetTester tester) async {
    await _withAndroidPlatform(() async {
      final TestData data = await _createTestDataInProcess();
      addTearDown(() => data.db.close());
      // 初始为关，便于验证「开启」路径。
      await data.settings.setValue(NotificationSettingsKeys.enabled, 'false');

      final List<String> permCalls = <String>[];
      _mockNotificationChannel(permCalls);
      final _FakeScheduler scheduler = _FakeScheduler();

      await _pumpPage(tester, data.settings, scheduler: scheduler);
      expect(_notifSwitchValue(tester), isFalse);

      await tester.tap(find.widgetWithText(SwitchListTile, '通知提醒'));
      await tester.pumpAndSettle();

      expect(_notifSwitchValue(tester), isTrue);
      expect(
        await data.settings.getValue(NotificationSettingsKeys.enabled),
        'true',
      );
      // 首次开启先申请通知权限（Android 13+）。
      expect(permCalls, contains('requestNotificationsPermission'));
      // 开启后全量重排。
      expect(scheduler.rescheduleCalls, 1);
      expect(scheduler.cancelCalls, 0);
    });
  });

  testWidgets('通知开关：关 → 写 false + 取消全部', (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());

    final _FakeScheduler scheduler = _FakeScheduler();
    await _pumpPage(tester, data.settings, scheduler: scheduler);
    expect(_notifSwitchValue(tester), isTrue);

    await tester.tap(find.widgetWithText(SwitchListTile, '通知提醒'));
    await tester.pumpAndSettle();

    expect(_notifSwitchValue(tester), isFalse);
    expect(
      await data.settings.getValue(NotificationSettingsKeys.enabled),
      'false',
    );
    expect(scheduler.cancelCalls, 1);
    expect(scheduler.rescheduleCalls, 0);
  });

  testWidgets('通知开关：首次开启 + 未展示过引导 → 跳保活引导页',
      (WidgetTester tester) async {
    await _withAndroidPlatform(() async {
      final TestData data = await _createTestDataInProcess();
      addTearDown(() => data.db.close());
      await data.settings.setValue(NotificationSettingsKeys.enabled, 'false');

      final List<String?> pushedRoutes = <String?>[];
      final List<String> permCalls = <String>[];
      _mockNotificationChannel(permCalls);

      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            settingsRepositoryProvider.overrideWithValue(data.settings),
            notificationSchedulerProvider.overrideWithValue(
              _FakeScheduler(showGuide: true),
            ),
          ],
          child: MaterialApp(
            home: const ReminderSettingsPage(),
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

      await tester.tap(find.widgetWithText(SwitchListTile, '通知提醒'));
      await tester.pumpAndSettle();

      expect(pushedRoutes, contains(AppRoutes.keepAliveGuide));
    });
  });

  testWidgets('通知开关：重排失败 → 提示且不崩', (WidgetTester tester) async {
    await _withAndroidPlatform(() async {
      final TestData data = await _createTestDataInProcess();
      addTearDown(() => data.db.close());
      await data.settings.setValue(NotificationSettingsKeys.enabled, 'false');

      final List<String> permCalls = <String>[];
      _mockNotificationChannel(permCalls);

      await _pumpPage(
        tester,
        data.settings,
        scheduler: _FakeScheduler(throwOnReschedule: true),
      );

      await tester.tap(find.widgetWithText(SwitchListTile, '通知提醒'));
      // 气泡由 AnimationController 驱动：用 pump 而非 pumpAndSettle。
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(_notifSwitchValue(tester), isTrue); // 失败不阻断设置
      expect(find.text('提醒重排失败，请稍后重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('通知开关：取消失败 → 提示且不崩', (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());

    await _pumpPage(
      tester,
      data.settings,
      scheduler: _FakeScheduler(throwOnCancel: true),
    );

    await tester.tap(find.widgetWithText(SwitchListTile, '通知提醒'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(_notifSwitchValue(tester), isFalse); // 失败不阻断设置
    expect(find.text('取消提醒失败，请稍后重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------- 课表同步提醒开关

  testWidgets('课表同步提醒：键不存在 → 缺省视为开', (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());

    await _pumpPage(tester, data.settings);

    expect(find.text('课表同步提醒'), findsOneWidget);
    expect(find.text('超过 7 天未同步教务课表时提醒'), findsOneWidget);
    expect(_eamsSwitchValue(tester), isTrue);
    expect(await data.settings.getValue(EamsSyncKeys.enabled), isNull);
  });

  testWidgets('课表同步提醒：键为 0 → 显示为关', (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());
    await data.settings.setValue(EamsSyncKeys.enabled, '0');

    await _pumpPage(tester, data.settings);

    expect(_eamsSwitchValue(tester), isFalse);
  });

  testWidgets("课表同步提醒：切换写入 '1' / '0'", (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());

    await _pumpPage(tester, data.settings);
    expect(_eamsSwitchValue(tester), isTrue);

    await tester.tap(find.widgetWithText(SwitchListTile, '课表同步提醒'));
    await tester.pumpAndSettle();
    expect(_eamsSwitchValue(tester), isFalse);
    expect(await data.settings.getValue(EamsSyncKeys.enabled), '0');

    await tester.tap(find.widgetWithText(SwitchListTile, '课表同步提醒'));
    await tester.pumpAndSettle();
    expect(_eamsSwitchValue(tester), isTrue);
    expect(await data.settings.getValue(EamsSyncKeys.enabled), '1');
  });

  testWidgets('课表同步提醒：写入失败 → 回滚显示值并报错', (WidgetTester tester) async {
    final _ThrowingSettingsRepo repo = _ThrowingSettingsRepo(<String, String>{});
    await _pumpPage(tester, repo);
    expect(_eamsSwitchValue(tester), isTrue);

    await tester.tap(find.widgetWithText(SwitchListTile, '课表同步提醒'));
    await tester.pump();
    await tester.pump();

    expect(_eamsSwitchValue(tester), isTrue);
    expect(find.text('保存失败，请稍后重试'), findsOneWidget);
  });

  testWidgets('提醒设置页：关闭课表同步提醒不清理另三个键',
      (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());
    await data.settings.setValue(EamsSyncKeys.enabled, '1');
    await data.settings.setValue(EamsSyncKeys.lastAt, '111');
    await data.settings.setValue(EamsSyncKeys.lastSemesterId, '7');
    await data.settings.setValue(EamsSyncKeys.nextRemindAt, '999');

    await _pumpPage(tester, data.settings);

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

  // ------------------------------------------------------- 提前量

  testWidgets('提前量：默认 10 分钟 → 选中 30 → 副标题随之变化并写库',
      (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());

    await _pumpPage(tester, data.settings);
    expect(find.text('上课前 10 分钟提醒'), findsOneWidget);

    await _tapTile(tester, '上课提醒提前量');
    // 弹窗出现。
    expect(find.text('30 分钟'), findsOneWidget);
    await tester.tap(find.text('30 分钟'));
    await tester.pumpAndSettle();

    expect(find.text('上课前 30 分钟提醒'), findsOneWidget);
    expect(
      await data.settings.getValue(NotificationSettingsKeys.classAdvanceMin),
      '30',
    );
  });

  testWidgets('提前量：选中 0 → 副标题显示「准时提醒」', (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());
    await data.settings.setValue(NotificationSettingsKeys.classAdvanceMin, '0');

    await _pumpPage(tester, data.settings);
    expect(find.text('准时提醒'), findsOneWidget);
  });

  // ------------------------------------------------------- 完成提示音

  testWidgets('提示音：选中内置 → 写库 + 副标题变名 + 出现清除按钮',
      (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());

    await _pumpPage(tester, data.settings);
    expect(find.text('未设置（完成任务时无音频反馈）'), findsOneWidget);
    expect(find.byTooltip('清除提示音'), findsNothing);

    await _tapTile(tester, '日程完成提示音');
    expect(find.text('steam成就'), findsOneWidget);
    await tester.tap(find.text('steam成就'));
    // 气泡由 AnimationController 驱动：用 pump（带时长让底部选择关闭动画走完），
    // 不能用 pumpAndSettle，否则气泡动画跑完已被移除。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('已设置完成提示音'), findsOneWidget);
    expect(find.byTooltip('清除提示音'), findsOneWidget);
    expect(find.text('steam成就'), findsOneWidget); // 副标题变为内置名
    expect(
      await data.settings.getValue(NotificationSettingsKeys.completeSound),
      'asset:steam_achievement',
    );
  });

  testWidgets('提示音：点清除 → 清空 + 副标题回「未设置」', (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());
    await data.settings.setValue(
      NotificationSettingsKeys.completeSound,
      'asset:steam_achievement',
    );

    await _pumpPage(tester, data.settings);
    expect(find.text('steam成就'), findsOneWidget);

    await tester.tap(find.byTooltip('清除提示音'));
    // 气泡断言须用 pump（pumpAndSettle 会把气泡动画跑完并移除）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('已清除日程完成提示音'), findsOneWidget);
    expect(find.text('未设置（完成任务时无音频反馈）'), findsOneWidget);
    expect(
      await data.settings.getValue(NotificationSettingsKeys.completeSound),
      '',
    );
  });

  // ------------------------------------------------------- 渠道直达

  testWidgets('渠道直达：点「课表提醒」→ classChannelId', (WidgetTester tester) async {
    final List<(String, Map<String, Object?>)> calls =
        <(String, Map<String, Object?>)>[];
    await _pumpWithChecker(tester, calls);

    await _tapTile(tester, '课表提醒');

    expect(calls, hasLength(1));
    expect(calls.single.$1, 'openSettings');
    expect(calls.single.$2['target'], 'notification');
    expect(calls.single.$2['channelId'], NotificationIds.classChannelId);
  });

  testWidgets('渠道直达：点「日程提醒」→ taskChannelId', (WidgetTester tester) async {
    final List<(String, Map<String, Object?>)> calls =
        <(String, Map<String, Object?>)>[];
    await _pumpWithChecker(tester, calls);

    await _tapTile(tester, '日程提醒');

    expect(calls, hasLength(1));
    expect(calls.single.$1, 'openSettings');
    expect(calls.single.$2['target'], 'notification');
    expect(calls.single.$2['channelId'], NotificationIds.taskChannelId);
  });

  testWidgets('提醒设置页：打开系统设置失败 → 报错气泡告知手动进入',
      (WidgetTester tester) async {
    final List<(String, Map<String, Object?>)> calls =
        <(String, Map<String, Object?>)>[];
    // 原生未确认打开（返回非 'opened'）→ openSettings 返回 false。
    await _pumpWithChecker(tester, calls, respond: null);

    await tester.tap(find.text('课表提醒'));
    // 气泡由 AnimationController 驱动：用 pump 而非 pumpAndSettle，
    // 否则动画跑完气泡已消失。两次 pump 让 openSettings 的 Future 落地并弹出。
    await tester.pump();
    await tester.pump();

    expect(find.text('无法打开系统设置页，请手动进入系统设置'), findsOneWidget);
  });

  // ------------------------------------------------------- 提醒保护

  testWidgets('提醒保护：点击跳转 keepAliveGuide', (WidgetTester tester) async {
    final List<String?> pushedRoutes = <String?>[];
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          notificationSchedulerProvider.overrideWithValue(_FakeScheduler()),
        ],
        child: MaterialApp(
          home: const ReminderSettingsPage(),
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

    expect(find.text('检测系统设置，确保提醒准时到达'), findsOneWidget);

    await _tapTile(tester, '提醒保护');
    expect(pushedRoutes, contains(AppRoutes.keepAliveGuide));
  });

  // ------------------------------------------------------- 窄屏大字体

  testWidgets('窄屏 + 大字体不溢出', (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());

    await _pumpPage(
      tester,
      data.settings,
      size: const Size(320, 640),
      textScaler: const TextScaler.linear(2.0),
    );

    await tester.scrollUntilVisible(
      find.text('日程完成提示音'),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('日程完成提示音'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
