import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:plai/features/schedule/schedule_providers.dart';
import 'package:plai/features/timetable/timetable_providers.dart';
import 'package:plai/services/audio/complete_sound.dart';
import 'package:plai/services/notifications/class_reminder_planner.dart';
import 'package:plai/services/notifications/notification_providers.dart';
import 'package:plai/services/notifications/notification_scheduler.dart';

/// 内存版 ITaskRepository：可把 `setCompleted` / `markDailyCompleted` 卡在
/// 未完成的 [Completer] 上，用于断言「此刻音效是否已起」（顺序回归）。
class _FakeTaskRepo implements ITaskRepository {
  _FakeTaskRepo(this._tasks);

  final Map<int, Task> _tasks;
  final Set<DateTime> _dailyDone = <DateTime>{};

  Completer<void>? blockSetCompleted;
  Completer<void>? blockMarkDaily;
  int getTasksCalls = 0;

  DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  void seedDailyDone(DateTime d) => _dailyDone.add(_day(d));

  @override
  Future<List<Task>> getTasks({
    TaskType? type,
    bool? completed,
    DateTime? from,
    DateTime? to,
  }) async {
    getTasksCalls++;
    return _tasks.values.toList();
  }

  @override
  Future<Task?> getTaskById(int id) async => _tasks[id];

  @override
  Future<int> insertTask(Task task) async => 0;

  @override
  Future<int> updateTask(Task task) async => 0;

  @override
  Future<int> deleteTask(int id) async => 0;

  @override
  Future<int> setCompleted(int id, bool completed) async {
    final Completer<void>? block = blockSetCompleted;
    if (block != null) await block.future;
    final Task? t = _tasks[id];
    if (t == null) return 0;
    _tasks[id] = t.copyWith(completed: completed);
    return 1;
  }

  @override
  Future<void> markDailyCompleted(int taskId, DateTime date) async {
    final Completer<void>? block = blockMarkDaily;
    if (block != null) await block.future;
    _dailyDone.add(_day(date));
  }

  @override
  Future<void> clearDailyCompleted(int taskId, DateTime date) async {
    _dailyDone.remove(_day(date));
  }

  @override
  Future<bool> isDailyCompleted(int taskId, DateTime date) async =>
      _dailyDone.contains(_day(date));

  @override
  Future<List<DateTime>> dailyLogsFor(int taskId) async =>
      _dailyDone.toList();
}

/// 内存设置（完成提示音键注入用）。
class _FakeSettings implements ISettingsRepository {
  _FakeSettings([Map<String, String>? values]) : values = Map.of(values ?? {});

  final Map<String, String> values;

  @override
  Future<String?> getValue(String key) async => values[key];

  @override
  Future<void> setValue(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> setAll(Map<String, String> entries) async {
    values.addAll(entries);
  }

  @override
  Future<Map<String, String>> getAll() async => Map.of(values);

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }
}

/// 记录点播路径的假完成音；可配置播放抛异常（验证静默不阻断）。
class _SoundRecorder implements CompletionSound {
  _SoundRecorder({this.throwOnPlay = false});

  final bool throwOnPlay;
  final List<String> paths = <String>[];

  @override
  Future<void> play(String path) async {
    paths.add(path);
    if (throwOnPlay) throw StateError('boom: play');
  }
}

/// 空操作假调度器：避免触碰真实平台通道。
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

/// 暴露 [WidgetRef] 并 watch [tasksProvider]（invalidate 可观测）。
class _Harness extends ConsumerWidget {
  const _Harness({required this.onRef});

  final void Function(WidgetRef ref) onRef;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onRef(ref);
    final AsyncValue<List<Task>> tasks = ref.watch(tasksProvider);
    return MaterialApp(
      home: Center(child: Text('n:${tasks.valueOrNull?.length ?? -1}')),
    );
  }
}

void main() {
  Task todo(int id, {bool completed = false}) => Task(
        id: id,
        title: '写作业',
        type: TaskType.todo,
        dueDate: DateTime(2026, 10, 7),
        completed: completed,
      );

  Task daily(int id) => Task(
        id: id,
        title: '每日喝水',
        type: TaskType.daily,
        startDate: DateTime(2026, 10, 1),
        dueDate: DateTime(2026, 10, 31),
      );

  Widget scope(
    _FakeTaskRepo repo, {
    required ISettingsRepository settings,
    required CompletionSound sound,
    required void Function(WidgetRef ref) onRef,
  }) {
    return ProviderScope(
      overrides: <Override>[
        taskRepositoryProvider.overrideWithValue(repo),
        settingsRepositoryProvider.overrideWithValue(settings),
        completionSoundPlayerProvider.overrideWithValue(sound),
        notificationSchedulerProvider.overrideWithValue(_FakeScheduler()),
      ],
      child: _Harness(onRef: onRef),
    );
  }

  _FakeSettings withSound() => _FakeSettings(<String, String>{
        NotificationSettingsKeys.completeSound: '/snd/a.mp3',
      });

  testWidgets('toggleTaskCompleted：setCompleted 卡住时音效已起（未排在写库之后）',
      (WidgetTester tester) async {
    final _FakeTaskRepo repo = _FakeTaskRepo(<int, Task>{1: todo(1)});
    final _SoundRecorder sound = _SoundRecorder();
    late WidgetRef ref;
    await tester.pumpWidget(scope(
      repo,
      settings: withSound(),
      sound: sound,
      onRef: (WidgetRef r) => ref = r,
    ));
    await tester.pumpAndSettle();

    repo.blockSetCompleted = Completer<void>();
    final Future<void> pending = toggleTaskCompleted(ref, repo._tasks[1]!);
    await tester.pump(); // 让 fire-and-forget 音效跑到播放

    // DB 写入仍卡着，但音效已触发 → 音效不排在 setCompleted 之后。
    expect(sound.paths, <String>['/snd/a.mp3']);

    repo.blockSetCompleted!.complete();
    await pending;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(repo._tasks[1]!.completed, isTrue);
  });

  testWidgets('toggleDailyCompleted：markDailyCompleted 卡住时音效已起（未排在写库之后）',
      (WidgetTester tester) async {
    final _FakeTaskRepo repo = _FakeTaskRepo(<int, Task>{1: daily(1)});
    final _SoundRecorder sound = _SoundRecorder();
    late WidgetRef ref;
    await tester.pumpWidget(scope(
      repo,
      settings: withSound(),
      sound: sound,
      onRef: (WidgetRef r) => ref = r,
    ));
    await tester.pumpAndSettle();

    repo.blockMarkDaily = Completer<void>();
    final Future<void> pending =
        toggleDailyCompleted(ref, repo._tasks[1]!, DateTime(2026, 10, 7));
    await tester.pump();

    expect(sound.paths, <String>['/snd/a.mp3']);

    repo.blockMarkDaily!.complete();
    await pending;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消完成不播音效', (WidgetTester tester) async {
    final _FakeTaskRepo repo = _FakeTaskRepo(<int, Task>{1: todo(1, completed: true)});
    final _SoundRecorder sound = _SoundRecorder();
    late WidgetRef ref;
    await tester.pumpWidget(scope(
      repo,
      settings: withSound(),
      sound: sound,
      onRef: (WidgetRef r) => ref = r,
    ));
    await tester.pumpAndSettle();

    await toggleTaskCompleted(ref, repo._tasks[1]!);
    await tester.pumpAndSettle();

    expect(sound.paths, isEmpty);
    expect(repo._tasks[1]!.completed, isFalse);
  });

  testWidgets('取消打卡不播音效', (WidgetTester tester) async {
    final _FakeTaskRepo repo = _FakeTaskRepo(<int, Task>{1: daily(1)});
    repo.seedDailyDone(DateTime(2026, 10, 7));
    final _SoundRecorder sound = _SoundRecorder();
    late WidgetRef ref;
    await tester.pumpWidget(scope(
      repo,
      settings: withSound(),
      sound: sound,
      onRef: (WidgetRef r) => ref = r,
    ));
    await tester.pumpAndSettle();

    await toggleDailyCompleted(ref, repo._tasks[1]!, DateTime(2026, 10, 7));
    await tester.pumpAndSettle();

    expect(sound.paths, isEmpty);
    expect(repo._dailyDone, isEmpty);
  });

  testWidgets('键为空：完成不播音效', (WidgetTester tester) async {
    final _FakeTaskRepo repo = _FakeTaskRepo(<int, Task>{1: todo(1)});
    final _SoundRecorder sound = _SoundRecorder();
    late WidgetRef ref;
    await tester.pumpWidget(scope(
      repo,
      settings: _FakeSettings(), // 无 complete_sound 键
      sound: sound,
      onRef: (WidgetRef r) => ref = r,
    ));
    await tester.pumpAndSettle();

    await toggleTaskCompleted(ref, repo._tasks[1]!);
    await tester.pumpAndSettle();

    expect(sound.paths, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('播放抛异常：静默，状态仍写成且 tasksProvider 仍被刷新',
      (WidgetTester tester) async {
    final _FakeTaskRepo repo = _FakeTaskRepo(<int, Task>{1: todo(1)});
    final _SoundRecorder sound = _SoundRecorder(throwOnPlay: true);
    late WidgetRef ref;
    await tester.pumpWidget(scope(
      repo,
      settings: withSound(),
      sound: sound,
      onRef: (WidgetRef r) => ref = r,
    ));
    await tester.pumpAndSettle();
    final int before = repo.getTasksCalls;

    await toggleTaskCompleted(ref, repo._tasks[1]!);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(repo._tasks[1]!.completed, isTrue); // 状态仍写成
    expect(repo.getTasksCalls, greaterThan(before)); // invalidate 仍执行
  });

  // tile 驱动的提交侧传 playSound: false（声音已由 tile 反馈在点击瞬间播过），
  // 断言这里不再调音效播放器 —— 同一次点击恰好响一次。
  testWidgets('toggleTaskCompleted(playSound: false)：完成不播音效，状态仍写成',
      (WidgetTester tester) async {
    final _FakeTaskRepo repo = _FakeTaskRepo(<int, Task>{1: todo(1)});
    final _SoundRecorder sound = _SoundRecorder();
    late WidgetRef ref;
    await tester.pumpWidget(scope(
      repo,
      settings: withSound(),
      sound: sound,
      onRef: (WidgetRef r) => ref = r,
    ));
    await tester.pumpAndSettle();
    final int before = repo.getTasksCalls;

    await toggleTaskCompleted(ref, repo._tasks[1]!, playSound: false);
    await tester.pumpAndSettle();

    expect(sound.paths, isEmpty); // 不播音效
    expect(repo._tasks[1]!.completed, isTrue); // 状态仍写成
    expect(repo.getTasksCalls, greaterThan(before)); // invalidate 仍执行
  });

  testWidgets('toggleDailyCompleted(playSound: false)：新打卡不播音效，记录仍写入',
      (WidgetTester tester) async {
    final _FakeTaskRepo repo = _FakeTaskRepo(<int, Task>{1: daily(1)});
    final _SoundRecorder sound = _SoundRecorder();
    late WidgetRef ref;
    await tester.pumpWidget(scope(
      repo,
      settings: withSound(),
      sound: sound,
      onRef: (WidgetRef r) => ref = r,
    ));
    await tester.pumpAndSettle();

    await toggleDailyCompleted(ref, repo._tasks[1]!, DateTime(2026, 10, 7),
        playSound: false);
    await tester.pumpAndSettle();

    expect(sound.paths, isEmpty); // 不播音效
    expect(repo._dailyDone, contains(DateTime(2026, 10, 7))); // 记录仍写入
  });
}
