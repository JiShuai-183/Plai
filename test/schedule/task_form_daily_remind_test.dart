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

/// 内存版 ITaskRepository：widget 测试不触 sqflite 真 IO（fake-async 可跑）。
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
  Future<void> scheduleTaskReminder(Task task, {bool? vibrate}) async {}

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

  Task dailyTask({String? time}) => Task(
        title: '每日喝水',
        type: TaskType.daily,
        startDate: DateTime(2026, 9, 1),
        dueDate: DateTime(2026, 9, 30),
        dailyRemindTime: time,
      );

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

  testWidgets('daily 编辑：显示「每日提醒时刻」与已设时刻；保存保留', (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeTaskRepo repo = _FakeTaskRepo();
    final Task seeded = repo.seed(dailyTask(time: '07:00'));

    await tester.pumpWidget(wrap(repo, seeded));
    await tester.pumpAndSettle();

    expect(find.text('每日提醒时刻'), findsOneWidget);
    expect(find.text('每天 07:00'), findsOneWidget);

    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();

    final Task? saved = await repo.getTaskById(seeded.id!);
    expect(saved!.dailyRemindTime, '07:00');
    expect(tester.takeException(), isNull);
  });

  testWidgets('daily 编辑：清除提醒时刻后保存为不提醒', (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeTaskRepo repo = _FakeTaskRepo();
    final Task seeded = repo.seed(dailyTask(time: '07:00'));

    await tester.pumpWidget(wrap(repo, seeded));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('清除每日提醒'));
    await tester.pumpAndSettle();
    expect(find.text('不提醒'), findsOneWidget);

    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();

    final Task? saved = await repo.getTaskById(seeded.id!);
    expect(saved!.dailyRemindTime, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('待办/定点/跨期编辑均显示「每日提醒时刻」且保留已设值，无旧提醒下拉', (WidgetTester tester) async {
    useTallSurface(tester);
    final List<TaskType> types = [TaskType.todo, TaskType.scheduled, TaskType.span];
    for (final TaskType type in types) {
      // 拆掉上一轮已 pop 成空栈的 Navigator，避免同 Element 复用致空历史断言。
      await tester.pumpWidget(const SizedBox());
      final _FakeTaskRepo repo = _FakeTaskRepo();
      final Task seeded = repo.seed(
        type == TaskType.span
            ? Task(
                title: '开题',
                type: TaskType.span,
                startDate: DateTime(2026, 9, 1),
                dueDate: DateTime(2026, 9, 10),
                dailyRemindTime: '06:00',
              )
            : Task(
                title: '复习',
                type: type,
                dueDate: DateTime(2026, 9, 30),
                dueTime: type == TaskType.scheduled ? '10:00' : null,
                dailyRemindTime: '06:00',
              ),
      );

      await tester.pumpWidget(wrap(repo, seeded));
      await tester.pumpAndSettle();

      expect(find.text('每日提醒时刻'), findsOneWidget, reason: 'type=$type');
      expect(find.text('每天 06:00'), findsOneWidget, reason: 'type=$type');
      // 旧版单次提醒下拉已移除。
      expect(find.text('提醒设置'), findsNothing, reason: 'type=$type');

      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();

      final Task? saved = await repo.getTaskById(seeded.id!);
      expect(saved!.dailyRemindTime, '06:00', reason: 'type=$type');
      expect(saved.remindOffsetMin, isNull, reason: 'type=$type');
      expect(tester.takeException(), isNull);
    }
  });
}
