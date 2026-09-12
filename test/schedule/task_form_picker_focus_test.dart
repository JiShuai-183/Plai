import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:plai/features/schedule/schedule_providers.dart';
import 'package:plai/features/schedule/task_form_page.dart';
import 'package:plai/services/notifications/class_reminder_planner.dart';
import 'package:plai/services/notifications/notification_providers.dart';
import 'package:plai/services/notifications/notification_scheduler.dart';

/// 内存版 ITaskRepository：widget 测试不触 sqflite 真 IO。
class _FakeTaskRepo implements ITaskRepository {
  final Map<int, Task> _byId = <int, Task>{};
  int _nextId = 1;

  Task seed(Task task) {
    final int id = _nextId++;
    final Task withId = task.copyWith(id: id);
    _byId[id] = withId;
    return withId;
  }

  @override
  Future<List<Task>> getTasks({
    TaskType? type,
    bool? completed,
    DateTime? from,
    DateTime? to,
  }) async =>
      _byId.values.toList();

  @override
  Future<Task?> getTaskById(int id) async => _byId[id];

  @override
  Future<int> insertTask(Task task) async {
    final int id = _nextId++;
    _byId[id] = task.copyWith(id: id);
    return id;
  }

  @override
  Future<int> updateTask(Task task) async {
    final int? id = task.id;
    if (id == null) return 0;
    _byId[id] = task;
    return 1;
  }

  @override
  Future<int> deleteTask(int id) async {
    _byId.remove(id);
    return 1;
  }

  @override
  Future<int> setCompleted(int id, bool completed) async {
    final Task? t = _byId[id];
    if (t == null) return 0;
    _byId[id] = t.copyWith(completed: completed);
    return 1;
  }

  @override
  Future<void> markDailyCompleted(int taskId, DateTime date) async {}

  @override
  Future<void> clearDailyCompleted(int taskId, DateTime date) async {}

  @override
  Future<bool> isDailyCompleted(int taskId, DateTime date) async => false;

  @override
  Future<List<DateTime>> dailyLogsFor(int taskId) async => const <DateTime>[];
}

/// 假提醒调度器：no-op（不触通知插件/真库）。
class _FakeScheduler extends NotificationScheduler {
  _FakeScheduler()
      : super(
          TimetableRepository(AppDatabase.instance),
          TaskRepository(AppDatabase.instance),
          SettingsRepository(AppDatabase.instance),
        );

  @override
  Future<void> scheduleTaskReminder(Task task) async {}

  @override
  Future<void> rescheduleAll({List<ClassReminderPlan>? classPlans}) async {}
}

void main() {
  /// 拉高测试视口：表单 ListView 整列在屏内，避免懒加载导致底部 tile 未构建。
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget wrap(_FakeTaskRepo repo, Task task) {
    return ProviderScope(
      overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        notificationSchedulerProvider.overrideWithValue(_FakeScheduler()),
        courseOptionsProvider.overrideWith(
          (ref) async => const <(int, String)>[],
        ),
      ],
      child: MaterialApp(home: TaskFormPage(task: task)),
    );
  }

  Task todo({String? dueTime}) => Task(
        title: '交作业',
        type: TaskType.todo,
        dueDate: DateTime(2026, 9, 30),
        dueTime: dueTime,
      );

  /// 回归：标题输入框取得焦点（键盘可见）后，打开「截止时刻」选择器并确定，
  /// 返回表单时键盘必须已收起（修复前会因底路由仍记着输入框而再次弹出）。
  testWidgets('选完截止时刻返回表单，软键盘不再弹出', (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeTaskRepo repo = _FakeTaskRepo();
    final Task seeded = repo.seed(todo());

    await tester.pumpWidget(wrap(repo, seeded));
    await tester.pumpAndSettle();

    // 前置：点标题输入框取得焦点，软键盘打开。
    await tester.tap(find.byType(TextFormField).first);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue,
        reason: '前置条件：标题获得焦点后键盘应可见');

    // 打开「截止时刻（可选）」拨盘，直接确定（初始 08:00）。
    await tester.tap(find.text('截止时刻（可选）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // 回归断言：返回表单后键盘收起。
    expect(tester.testTextInput.isVisible, isFalse,
        reason: '选完时刻返回表单，软键盘不应再次弹出');
    // 功能未被破坏：选中的时刻写入表单。
    expect(find.text('08:00'), findsOneWidget);

    // 保存后确认落库。
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();
    final Task? saved = await repo.getTaskById(seeded.id!);
    expect(saved!.dueTime, '08:00');
    expect(tester.takeException(), isNull);
  });

  /// 同缺陷的日期入口：选完日期返回表单同样不应弹键盘。
  testWidgets('选完日期返回表单，软键盘不再弹出', (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeTaskRepo repo = _FakeTaskRepo();
    final Task seeded = repo.seed(todo());

    await tester.pumpWidget(wrap(repo, seeded));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextFormField).first);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(find.text('日期'));
    await tester.pumpAndSettle();
    // 默认英文 Material 本地化：日期选择器确认按钮为 OK。
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(tester.testTextInput.isVisible, isFalse,
        reason: '选完日期返回表单，软键盘不应再次弹出');
    expect(tester.takeException(), isNull);
  });
}
