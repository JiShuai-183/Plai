import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:plai/features/schedule/schedule_providers.dart';
import 'package:plai/features/schedule/task_list_tile.dart';
import 'package:plai/features/timetable/timetable_providers.dart';
import 'package:plai/services/audio/complete_sound.dart';
import 'package:plai/services/notifications/class_reminder_planner.dart';
import 'package:plai/services/notifications/notification_providers.dart';
import 'package:plai/services/notifications/notification_scheduler.dart';

/// [TaskListTile.onCompleteFeedback]（点即响）交互测试：
/// - 只在「未完成 → 完成」分支、点击瞬间（划线动画开始前）同步触发；
/// - 与 [onToggle] 的顺序：feedback 早于 toggle（toggle 仍等 250ms 动画播完）；
/// - 「已完成 → 取消」不触发；
/// - 动画中重复点击被忽略，feedback / toggle 各只一次；
/// - 按真实页面接线（feedback 出声 + 提交侧 playSound:false）：一次点击恰好响一次。
void main() {
  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: ListView(children: [child])));

  Task todoTask({bool completed = false, int? id}) => Task(
        id: id,
        title: '写作业',
        type: TaskType.todo,
        dueDate: DateTime(2026, 9, 20),
        completed: completed,
      );

  testWidgets('未完成→完成：反馈在点击当帧同步触发，onToggle 等动画播完才触发（顺序 feedback 先于 toggle）',
      (WidgetTester tester) async {
    final List<String> log = <String>[];
    await tester.pumpWidget(wrap(TaskListTile(
      task: todoTask(),
      onCompleteFeedback: () => log.add('feedback'),
      onToggle: () => log.add('toggle'),
    )));

    await tester.tap(find.byType(Checkbox));
    await tester.pump(); // 点击当帧：动画尚未推进
    // 反馈已出，尚未提交（仍在动画中）。
    expect(log, <String>['feedback']);

    await tester.pump(const Duration(milliseconds: 100)); // 动画进行中
    expect(log, <String>['feedback']);

    await tester.pump(const Duration(milliseconds: 200)); // 越过 250ms
    expect(log, <String>['feedback', 'toggle']); // 顺序：feedback 先于 toggle
  });

  testWidgets('已完成→取消：不触发 onCompleteFeedback，onToggle 立即调用',
      (WidgetTester tester) async {
    final List<String> log = <String>[];
    await tester.pumpWidget(wrap(TaskListTile(
      task: todoTask(completed: true),
      onCompleteFeedback: () => log.add('feedback'),
      onToggle: () => log.add('toggle'),
    )));

    await tester.tap(find.byType(Checkbox));
    await tester.pump();

    expect(log, <String>['toggle']); // 只有提交，无反馈
    await tester.pumpAndSettle();
    expect(log, <String>['toggle']);
  });

  testWidgets('防重入：动画期间重复点击，feedback 与 onToggle 各只触发一次',
      (WidgetTester tester) async {
    final List<String> log = <String>[];
    await tester.pumpWidget(wrap(TaskListTile(
      task: todoTask(),
      onCompleteFeedback: () => log.add('feedback'),
      onToggle: () => log.add('toggle'),
    )));

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100)); // 动画中
    await tester.tap(find.byType(Checkbox)); // 重复点击 → 忽略
    await tester.pump();
    await tester.tap(find.byType(Checkbox)); // 再点 → 忽略
    await tester.pump(const Duration(milliseconds: 100));
    expect(log, <String>['feedback']); // 反馈仅一次

    await tester.pump(const Duration(milliseconds: 60)); // 越过 250ms
    expect(log, <String>['feedback', 'toggle']); // 各一次
  });

  testWidgets('真实接线：一次点击恰好响一次（tile 反馈出声 + 提交侧 playSound:false）',
      (WidgetTester tester) async {
    final _FakeTaskRepo repo = _FakeTaskRepo(todoTask(id: 1));
    final _SoundRecorder sound = _SoundRecorder();
    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[
        taskRepositoryProvider.overrideWithValue(repo),
        settingsRepositoryProvider.overrideWithValue(_FakeSettings(<String, String>{
          NotificationSettingsKeys.completeSound: '/snd/a.mp3',
        })),
        completionSoundPlayerProvider.overrideWithValue(sound),
        notificationSchedulerProvider.overrideWithValue(_FakeScheduler()),
      ],
      child: _TileHarness(task: repo.task),
    ));

    await tester.tap(find.byType(Checkbox));
    // 点击瞬间即刻出声（不等 250ms 动画）。
    await tester.pump();
    expect(sound.paths, <String>['/snd/a.mp3']);

    // 动画播完 → 提交侧 playSound:false → 不二次出声。
    await tester.pumpAndSettle();
    expect(sound.paths, <String>['/snd/a.mp3']); // 恰好一次
    expect(repo.task.completed, isTrue);
    expect(tester.takeException(), isNull);
  });
}

/// 按真实页面接线：勾选完成时 tile 反馈即时出声，提交侧用 `playSound: false`。
class _TileHarness extends ConsumerWidget {
  const _TileHarness({required this.task});

  final Task task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      home: Scaffold(
        body: ListView(
          children: <Widget>[
            TaskListTile(
              task: task,
              onCompleteFeedback: () => playCompletionSoundOnTap(ref),
              onToggle: () => toggleTaskCompleted(ref, task, playSound: false),
            ),
          ],
        ),
      ),
    );
  }
}

/// 内存版 ITaskRepository（单个任务，setCompleted 真翻转）。
class _FakeTaskRepo implements ITaskRepository {
  _FakeTaskRepo(this.task);

  Task task;

  @override
  Future<List<Task>> getTasks({
    TaskType? type,
    bool? completed,
    DateTime? from,
    DateTime? to,
  }) async =>
      <Task>[task];

  @override
  Future<Task?> getTaskById(int id) async => task.id == id ? task : null;

  @override
  Future<int> insertTask(Task t) async => 0;

  @override
  Future<int> updateTask(Task t) async => 0;

  @override
  Future<int> deleteTask(int id) async => 0;

  @override
  Future<int> setCompleted(int id, bool completed) async {
    task = task.copyWith(completed: completed);
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

/// 内存设置（注入完成提示音键）。
class _FakeSettings implements ISettingsRepository {
  _FakeSettings(this.values);

  final Map<String, String> values;

  @override
  Future<String?> getValue(String key) async => values[key];

  @override
  Future<void> setValue(String key, String value) async => values[key] = value;

  @override
  Future<void> setAll(Map<String, String> entries) async =>
      values.addAll(entries);

  @override
  Future<Map<String, String>> getAll() async => Map.of(values);

  @override
  Future<void> remove(String key) async => values.remove(key);
}

/// 记录点播路径的假完成音。
class _SoundRecorder implements CompletionSound {
  final List<String> paths = <String>[];

  @override
  Future<void> play(String path) async => paths.add(path);
}

/// 空操作假调度器（避免触真实平台通道）。
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
  Future<void> cancelAllRemindersFor({int? taskId, int? courseId}) async {}

  @override
  Future<void> rescheduleAll({List<ClassReminderPlan>? classPlans}) async {}
}
