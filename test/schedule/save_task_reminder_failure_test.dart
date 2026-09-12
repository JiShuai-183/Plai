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

/// 可配置抛异常的假调度器：模拟「设了每日提醒时刻后平台调度失败」。
class _FakeScheduler extends NotificationScheduler {
  _FakeScheduler({this.throwOnSchedule = false, this.throwOnCancel = false})
      : super(
          TimetableRepository(AppDatabase.instance),
          TaskRepository(AppDatabase.instance),
          SettingsRepository(AppDatabase.instance),
        );

  final bool throwOnSchedule;
  final bool throwOnCancel;

  @override
  Future<void> scheduleTaskReminder(Task task) async {
    if (throwOnSchedule) throw StateError('boom: schedule');
  }

  @override
  Future<void> cancelAllRemindersFor({int? taskId, int? courseId}) async {
    if (throwOnCancel) throw StateError('boom: cancel');
  }

  @override
  Future<void> rescheduleAll({List<ClassReminderPlan>? classPlans}) async {}
}

/// 暴露 [WidgetRef] 并展示当前 [tasksProvider] 数量的测试壳。
class _Harness extends ConsumerWidget {
  const _Harness({required this.onRef});

  final void Function(WidgetRef ref) onRef;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onRef(ref);
    final AsyncValue<List<Task>> tasks = ref.watch(tasksProvider);
    return MaterialApp(
      home: Center(child: Text('tasks:${tasks.valueOrNull?.length ?? -1}')),
    );
  }
}

void main() {
  Task dailyTask({String? time}) => Task(
        title: '每日喝水',
        type: TaskType.daily,
        startDate: DateTime(2026, 9, 1),
        dueDate: DateTime(2026, 9, 30),
        dailyRemindTime: time,
      );

  Widget scope(
    _FakeTaskRepo repo,
    _FakeScheduler scheduler, {
    required void Function(WidgetRef ref) onRef,
  }) {
    return ProviderScope(
      overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        notificationSchedulerProvider.overrideWithValue(scheduler),
        courseOptionsProvider.overrideWith((ref) async => const <(int, String)>[]),
      ],
      child: _Harness(onRef: onRef),
    );
  }

  testWidgets('调度抛异常：saveTask 不抛、返回 id、任务入库、回调触发',
      (WidgetTester tester) async {
    final _FakeTaskRepo repo = _FakeTaskRepo();
    late WidgetRef ref;
    await tester.pumpWidget(scope(
      repo,
      _FakeScheduler(throwOnSchedule: true),
      onRef: (WidgetRef r) => ref = r,
    ));
    await tester.pumpAndSettle();

    bool reminderFailed = false;
    final int? id = await saveTask(
      ref,
      dailyTask(time: '07:00'),
      onReminderFailed: () => reminderFailed = true,
    );
    await tester.pumpAndSettle();

    expect(id, isNotNull);
    expect(await repo.getTaskById(id!), isNotNull);
    expect(reminderFailed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('调度抛异常：tasksProvider 仍被刷新（无幽灵任务）',
      (WidgetTester tester) async {
    final _FakeTaskRepo repo = _FakeTaskRepo();
    late WidgetRef ref;
    await tester.pumpWidget(scope(
      repo,
      _FakeScheduler(throwOnSchedule: true),
      onRef: (WidgetRef r) => ref = r,
    ));
    await tester.pumpAndSettle();
    expect(find.text('tasks:0'), findsOneWidget);

    await saveTask(ref, dailyTask(time: '07:00'));
    await tester.pumpAndSettle();

    // 第③步 invalidate 未被异常跳过：新任务立即出现在列表数据中。
    expect(find.text('tasks:1'), findsOneWidget);
  });

  testWidgets('调度正常：回调不触发', (WidgetTester tester) async {
    final _FakeTaskRepo repo = _FakeTaskRepo();
    late WidgetRef ref;
    await tester.pumpWidget(scope(
      repo,
      _FakeScheduler(),
      onRef: (WidgetRef r) => ref = r,
    ));
    await tester.pumpAndSettle();

    bool reminderFailed = false;
    await saveTask(
      ref,
      dailyTask(time: '07:00'),
      onReminderFailed: () => reminderFailed = true,
    );
    await tester.pumpAndSettle();

    expect(reminderFailed, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('deleteTask：取消提醒抛异常时不抛、且 invalidate 仍执行',
      (WidgetTester tester) async {
    final _FakeTaskRepo repo = _FakeTaskRepo();
    final Task seeded = repo.seed(dailyTask(time: '07:00'));
    late WidgetRef ref;
    await tester.pumpWidget(scope(
      repo,
      _FakeScheduler(throwOnCancel: true),
      onRef: (WidgetRef r) => ref = r,
    ));
    await tester.pumpAndSettle();
    expect(find.text('tasks:1'), findsOneWidget);

    await deleteTask(ref, seeded.id!);
    await tester.pumpAndSettle();

    expect(find.text('tasks:0'), findsOneWidget);
    expect(await repo.getTaskById(seeded.id!), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('表单：调度失败时保存后仍 pop，并弹「任务已保存，但提醒设置失败」气泡',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _FakeTaskRepo repo = _FakeTaskRepo();
    final Task seeded = repo.seed(dailyTask(time: '07:00'));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          taskRepositoryProvider.overrideWithValue(repo),
          notificationSchedulerProvider
              .overrideWithValue(_FakeScheduler(throwOnSchedule: true)),
          courseOptionsProvider
              .overrideWith((ref) async => const <(int, String)>[]),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => TaskFormPage(task: seeded),
                    ),
                  ),
                  child: const Text('打开表单'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开表单'));
    await tester.pumpAndSettle();
    expect(find.byType(TaskFormPage), findsOneWidget);

    await tester.tap(find.text('保存修改'));
    // 让保存异步链路跑完（入库 → 调度失败 → pop）并推完返回动画（约 300ms）。
    for (int i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(TaskFormPage).evaluate().isEmpty) break;
    }

    // 任务确已保存、表单已返回上一页。
    final Task? saved = await repo.getTaskById(seeded.id!);
    expect(saved!.dailyRemindTime, '07:00');
    expect(find.byType(TaskFormPage), findsNothing);
    // 气泡在上一页可见（1s 时长内，此处刚过 400ms）。
    expect(find.text('任务已保存，但提醒设置失败'), findsOneWidget);

    // 收尾：跑完气泡动画，避免残留计时器。
    await tester.pumpAndSettle();
    expect(find.text('任务已保存，但提醒设置失败'), findsNothing);
  });
}
