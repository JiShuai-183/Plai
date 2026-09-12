import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/holiday.dart';
import 'package:plai/data/models/period.dart';
import 'package:plai/data/models/semester.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:plai/features/timetable/format.dart';
import 'package:plai/features/timetable/period_page.dart';
import 'package:plai/features/timetable/semester_page.dart';
import 'package:plai/features/timetable/timetable_providers.dart';
import 'package:plai/services/notifications/class_reminder_planner.dart';
import 'package:plai/services/notifications/notification_providers.dart';
import 'package:plai/services/notifications/notification_scheduler.dart';

/// 内存课表仓库：只实现页面与本用例用到的读写，其余交由 `noSuchMethod` 报错。
class _FakeTimetableRepository implements ITimetableRepository {
  final List<Period> insertedPeriods = <Period>[];

  @override
  Future<List<Period>> getPeriods() async => const <Period>[];

  @override
  Future<int> insertPeriod(Period period) async {
    insertedPeriods.add(period);
    return insertedPeriods.length;
  }

  @override
  Future<List<Semester>> getSemesters() async => const <Semester>[];

  @override
  Future<List<Course>> getAllCourses() async => const <Course>[];

  @override
  Future<List<Holiday>> getHolidays({
    int? courseId,
    DateTime? from,
    DateTime? to,
  }) async =>
      const <Holiday>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 内存设置仓库：全部键缺省。
class _FakeSettingsRepository implements ISettingsRepository {
  @override
  Future<String?> getValue(String key) async => null;

  @override
  Future<Map<String, String>> getAll() async => const <String, String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 无操作任务仓库：`rescheduleTimetableReminders` 不读取任务。
class _NoopTaskRepository implements ITaskRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 跳过真实通知插件的调度器替身。
class _FakeScheduler extends NotificationScheduler {
  _FakeScheduler(super.timetable, super.tasks, super.settings);

  @override
  Future<void> rescheduleAll({List<ClassReminderPlan>? classPlans}) async {}
}

void main() {
  /// 拉高视口：对话框整列在屏内，免滚动手势。
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  List<Override> overrides(_FakeTimetableRepository repo) {
    final _FakeSettingsRepository settings = _FakeSettingsRepository();
    return <Override>[
      timetableRepositoryProvider.overrideWithValue(repo),
      settingsRepositoryProvider.overrideWithValue(settings),
      notificationSchedulerProvider.overrideWithValue(
        _FakeScheduler(repo, _NoopTaskRepository(), settings),
      ),
    ];
  }

  /// 回归：节次序号输入框取得焦点（键盘可见）后，打开「开始时间」拨盘并确定，
  /// 返回对话框时键盘必须已收起（修复前会因底路由仍记着输入框而再次弹出）。
  testWidgets('选完开始时刻返回节次对话框，软键盘不再弹出', (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeTimetableRepository repo = _FakeTimetableRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(repo),
        child: const MaterialApp(home: PeriodManagePage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加节次'));
    await tester.pumpAndSettle();

    // 前置：点节次序号输入框取得焦点，软键盘打开。
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue,
        reason: '前置条件：节次序号输入框获得焦点后键盘应可见');

    // 打开「开始时间」拨盘，点盘顶把初始 08:00 改为 00:00，再确定。
    await tester.tap(find.text('开始时间'));
    await tester.pumpAndSettle();
    final Rect dial = tester.getRect(find.byKey(const Key('plai_dial')));
    await tester.tapAt(dial.topCenter + Offset(0, dial.height * 0.15));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // 回归断言：返回对话框后键盘收起。
    expect(tester.testTextInput.isVisible, isFalse,
        reason: '选完时刻返回对话框，软键盘不应再次弹出');
    // 功能未被破坏：选中的时刻写回对话框（08:00 → 00:00）。
    expect(find.text('00:00'), findsOneWidget);

    // 保存后确认落库，选中时刻确实进入 Period。
    await tester.enterText(find.byType(TextField), '1');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(repo.insertedPeriods, hasLength(1));
    expect(repo.insertedPeriods.single.startTime, '00:00');
    expect(repo.insertedPeriods.single.endTime, '08:45');
    expect(tester.takeException(), isNull);
  });

  /// 同缺陷的学期「开学日期」入口：学期名称输入框 autofocus（进对话框键盘即开），
  /// 选完日期返回后键盘同样不应再次弹出。
  testWidgets('选完开学日期返回学期对话框，软键盘不再弹出', (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeTimetableRepository repo = _FakeTimetableRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(repo),
        child: const MaterialApp(home: SemesterManagePage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建学期'));
    await tester.pumpAndSettle();

    // 前置：学期名称输入框 autofocus，键盘可见。
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue,
        reason: '前置条件：学期名称输入框获得焦点后键盘应可见');

    // 打开「开学日期」日期选择器，选另一个日期后确定。
    await tester.tap(find.text('开学日期'));
    await tester.pumpAndSettle();
    final DateTime now = DateTime.now();
    final int targetDay = now.day == 15 ? 16 : 15;
    await tester.tap(find.text('$targetDay'));
    await tester.pumpAndSettle();
    // 默认英文 Material 本地化：日期选择器确认按钮为 OK。
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    // 回归断言：返回对话框后键盘收起。
    expect(tester.testTextInput.isVisible, isFalse,
        reason: '选完日期返回对话框，软键盘不应再次弹出');
    // 功能未被破坏：选中的日期写回对话框副标题。
    final String expected =
        formatFullDate(DateTime(now.year, now.month, targetDay));
    expect(find.text(expected), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
