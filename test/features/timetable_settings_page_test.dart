import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:plai/features/settings/settings_providers.dart';
import 'package:plai/features/settings/timetable_settings_page.dart';
import 'package:plai/features/timetable/timetable_settings_keys.dart';

import '../data/test_helpers.dart';

/// 建 in-memory 测试库 —— **必须用 `databaseFactoryFfiNoIsolate`**。
///
/// `TestData.create()` 用默认的 `databaseFactoryFfi`（SQLite 跑在后台 isolate，
/// 真实异步 I/O），在 `testWidgets` 的假时钟 zone 下 Future 永不完成、用例挂死。
/// `databaseFactoryFfiNoIsolate` 同进程执行，假时钟下正常。
/// 见 `test/features/settings_page_test.dart` 的同类写法。
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

/// 内存版设置仓库：记录 `getAll` 调用次数（验证写后 provider 被 invalidate 重读）
/// 与写入内容。
class _FakeSettingsRepo implements ISettingsRepository {
  _FakeSettingsRepo([Map<String, String>? initial])
      : _values = Map<String, String>.of(initial ?? const <String, String>{});

  final Map<String, String> _values;

  /// `getAll` 被调用次数；每次 provider 重算（含 invalidate 后）都会 +1。
  int getAllCalls = 0;

  /// 按顺序记录每次 `setValue` 的 (key, value)。
  final List<MapEntry<String, String>> writes = <MapEntry<String, String>>[];

  @override
  Future<Map<String, String>> getAll() async {
    getAllCalls++;
    return Map<String, String>.of(_values);
  }

  @override
  Future<String?> getValue(String key) async => _values[key];

  @override
  Future<void> setValue(String key, String value) async {
    _values[key] = value;
    writes.add(MapEntry<String, String>(key, value));
  }

  @override
  Future<void> setAll(Map<String, String> entries) async =>
      _values.addAll(entries);

  @override
  Future<void> remove(String key) async => _values.remove(key);
}

/// 写失败注入仓库：读取正常，`setValue` 一律抛错，用于验证失败回滚 + 报错。
class _ThrowingSettingsRepo implements ISettingsRepository {
  _ThrowingSettingsRepo(this._values);

  final Map<String, String> _values;

  @override
  Future<Map<String, String>> getAll() async => Map<String, String>.of(_values);

  @override
  Future<String?> getValue(String key) async => _values[key];

  @override
  Future<void> setValue(String key, String value) async =>
      throw StateError('boom');

  @override
  Future<void> setAll(Map<String, String> entries) async =>
      throw StateError('boom');

  @override
  Future<void> remove(String key) async => throw StateError('boom');
}

/// 挂载课表设置页并注入设置仓库（其余 provider 与生产一致）。
Future<void> _pumpPage(
  WidgetTester tester,
  ISettingsRepository repo, {
  Size size = const Size(800, 2000),
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        // 写入与读取都走这唯一的设置仓库 provider
        //（课表模块的 settingsRepositoryProvider 只是转出同一对象）。
        settingsRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: const TimetableSettingsPage(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 顶层的「周视图显示节次时间」开关控件。
SwitchListTile _weekSwitch(WidgetTester tester) => tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '周视图显示节次时间'),
    );

bool _weekSwitchValue(WidgetTester tester) => _weekSwitch(tester).value;

Future<void> _tapWeekSwitch(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(SwitchListTile, '周视图显示节次时间'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('课表设置页：DB 不可用时三组标题与全部设置项正常渲染', (WidgetTester tester) async {
    // 高视口让 ListView 一次性构建全部分组项，避免懒加载漏查。
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 无 DB（宿主测试环境）→ provider 兜底默认值、节次数兜底 0，页面照常渲染。
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: TimetableSettingsPage())),
    );
    await tester.pumpAndSettle();

    // 三个分组标题：节次时间表标题与入口 ListTile 标题各一，共 2 个。
    expect(find.text('节次时间表'), findsNWidgets(2));
    expect(find.text('课表颜色'), findsOneWidget);
    expect(find.text('样式'), findsOneWidget);

    // 课表颜色组：三种状态色。
    expect(find.text('正在上课'), findsOneWidget);
    expect(find.text('还未上课'), findsOneWidget);
    expect(find.text('已经下课'), findsOneWidget);

    // 样式组：默认课程颜色 / 状态色总开关 / 周视图节次时间 / 已结束文字淡化 / 细化。
    expect(find.text('电脑端课表缩放'), findsNothing);
    expect(find.text('默认课程颜色'), findsOneWidget);
    expect(find.text('状态色总开关'), findsOneWidget);
    expect(find.text('周视图显示节次时间'), findsOneWidget);
    expect(find.text('已结束文字淡化'), findsOneWidget);
    expect(find.text('已结束文字细化'), findsOneWidget);

    // 节次时间表入口副标题（兜底 0 节）。
    expect(find.text('共 0 节 · 编辑各节起止时间'), findsOneWidget);
  });

  // -------------------------------------------------- 周视图显示节次时间

  testWidgets('周视图显示节次时间：键缺失 → 显示为开（默认）', (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());

    await _pumpPage(tester, data.settings);

    expect(find.text('周视图显示节次时间'), findsOneWidget);
    expect(_weekSwitchValue(tester), isTrue);
    // 缺省不写入任何值。
    expect(
      await data.settings.getValue(TimetableSettingsKeys.weekViewPeriodTime),
      isNull,
    );
  });

  testWidgets("周视图显示节次时间：键为 'false' → 显示为关", (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());
    await data.settings.setValue(TimetableSettingsKeys.weekViewPeriodTime, 'false');

    await _pumpPage(tester, data.settings);

    expect(_weekSwitchValue(tester), isFalse);
  });

  testWidgets("周视图显示节次时间：切换写入 'true' / 'false'（非 '0'/'1'）",
      (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());

    await _pumpPage(tester, data.settings);
    expect(_weekSwitchValue(tester), isTrue);

    // 开 → 关：写 'false'。
    await _tapWeekSwitch(tester);
    expect(_weekSwitchValue(tester), isFalse);
    expect(
      await data.settings.getValue(TimetableSettingsKeys.weekViewPeriodTime),
      'false',
    );

    // 关 → 开：写 'true'。
    await _tapWeekSwitch(tester);
    expect(_weekSwitchValue(tester), isTrue);
    expect(
      await data.settings.getValue(TimetableSettingsKeys.weekViewPeriodTime),
      'true',
    );
  });

  testWidgets('周视图显示节次时间：写入失败 → 回滚显示值并报错', (WidgetTester tester) async {
    final _ThrowingSettingsRepo repo = _ThrowingSettingsRepo(<String, String>{});
    await _pumpPage(tester, repo);
    expect(_weekSwitchValue(tester), isTrue);

    await tester.tap(find.widgetWithText(SwitchListTile, '周视图显示节次时间'));
    // 气泡由 AnimationController 驱动：用 pump 而非 pumpAndSettle，
    // 否则动画跑完气泡已消失。两次 pump 让写失败的 Future 落地。
    await tester.pump();
    await tester.pump();

    // 回滚到原值（未被留在错的关闭态）。
    expect(_weekSwitchValue(tester), isTrue);
    expect(find.text('保存失败，请稍后重试'), findsOneWidget);
  });

  testWidgets('周视图显示节次时间：切换后 timetableStatusSettingsProvider 被 invalidate 重读',
      (WidgetTester tester) async {
    final _FakeSettingsRepo repo = _FakeSettingsRepo();
    await _pumpPage(tester, repo);

    // 首帧 provider 解析 → getAll 至少一次。
    final int before = repo.getAllCalls;
    expect(before, greaterThan(0));

    await _tapWeekSwitch(tester);

    // invalidate 触发 provider 重算 → getAll 再被调用（周视图会重读）。
    expect(repo.getAllCalls, greaterThan(before));
    // 且确实写入了 'false'。
    expect(repo.writes.single.key, TimetableSettingsKeys.weekViewPeriodTime);
    expect(repo.writes.single.value, 'false');
  });

  testWidgets('周视图显示节次时间：窄屏 + 大字体不溢出', (WidgetTester tester) async {
    final TestData data = await _createTestDataInProcess();
    addTearDown(() => data.db.close());

    await _pumpPage(
      tester,
      data.settings,
      size: const Size(320, 640),
      textScaler: const TextScaler.linear(2.0),
    );

    // 滚到新开关，触发懒加载构建，检查窄屏大字体下未溢出。
    await tester.scrollUntilVisible(
      find.text('周视图显示节次时间'),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('周视图显示节次时间'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
