import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/models/semester.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:plai/features/timetable/eams/eams_import_page.dart';
import 'package:plai/features/timetable/timetable_page.dart';
import 'package:plai/features/timetable/timetable_providers.dart';
import 'package:plai/routes/app_routes.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/test_helpers.dart';

/// 建 in-memory 测试库 —— **必须用 `databaseFactoryFfiNoIsolate`**。
///
/// `TestData.create()`（`test/data/test_helpers.dart`）用的是默认的
/// `databaseFactoryFfi`，它把 SQLite 跑在**后台 isolate** 里 → 真实异步 I/O。
/// 而 `testWidgets` 的 body 跑在**假时钟 zone**，真实 I/O 的 Future 永远不会完成，
/// 于是 `await db.database` 卡死、整个用例无限期挂起。
/// 实测症状：用例名打印出来后卡住 90s+ 不报错、不超时（`--timeout` 也不生效，
/// 因为挂在 `testWidgets` 之外的 `await` 上）。
/// 该工厂同进程同步执行，Future 走微任务即可完成，假时钟下正常。
///
/// ⚠️ 这也是**本仓库第一个真正建库并渲染 `TimetablePage` 的 widget 测试**
/// （`test/widget_test.dart` 里 `TimetablePage` 是懒加载，从未真正构建；
/// 既有 widget 测试走的是「DB 不可用」降级路径，从不建库）。
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

/// 装配课表页：in-memory 库（不碰生产单例）+ 命名路由表（含教务导入页，
/// 故点击入口后可真实跳转，且**不发任何网络**）。
Future<void> _mountTimetablePage(
  WidgetTester tester, {
  Semester? semester,
}) async {
  final TestData data = await _createTestDataInProcess();
  addTearDown(() => data.db.close());
  if (semester != null) {
    await data.timetable.insertSemester(semester);
  }

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        timetableRepositoryProvider.overrideWithValue(data.timetable),
        settingsRepositoryProvider.overrideWithValue(data.settings),
      ],
      child: MaterialApp(
        routes: <String, WidgetBuilder>{
          AppRoutes.eamsImport: (_) => const EamsImportPage(),
        },
        home: const TimetablePage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 显式卸载 —— 触发 `WeekView.dispose()` 取消其 `Timer.periodic`，
/// 避免收尾报 “A Timer is still pending even after the widget tree was disposed”。
Future<void> _unmount(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

Semester _semester({String name = '2026 秋'}) => Semester(
      name: name,
      startDate: DateTime(2026, 9, 1),
      totalWeeks: 16,
    );

void main() {
  testWidgets('有学期：AppBar 左上角有「从教务导入」图标，点击跳转到 EamsImportPage',
      (WidgetTester tester) async {
    await _mountTimetablePage(tester, semester: _semester());

    final Finder sync = find.widgetWithIcon(IconButton, Icons.sync);
    expect(sync, findsOneWidget);

    await tester.tap(sync);
    await tester.pumpAndSettle();

    expect(find.byType(EamsImportPage), findsOneWidget);
    expect(find.text('从教务导入课表'), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets('无学期（空态视图）：没有该图标', (WidgetTester tester) async {
    await _mountTimetablePage(tester);

    expect(find.text('课表'), findsOneWidget);
    expect(find.byIcon(Icons.sync), findsNothing);

    await _unmount(tester);
  });

  testWidgets('窄屏 + 长学期名：标题被截断且不与左侧图标重叠',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const String longName = '2026-2027学年第一学期（本科·航空工程专业·飞行器设计方向）';
    await _mountTimetablePage(tester, semester: _semester(name: longName));

    // 无布局溢出异常。
    expect(tester.takeException(), isNull);

    final Rect icon = tester.getRect(find.byIcon(Icons.sync));
    final Rect title = tester.getRect(find.text(longName));
    // 标题起点在图标右侧（未叠压），右端未越过屏幕（被 ellipsis 截断）。
    expect(title.left, greaterThanOrEqualTo(icon.right));
    expect(title.right, lessThanOrEqualTo(320));

    await _unmount(tester);
  });
}
