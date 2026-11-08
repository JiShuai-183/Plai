import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/data/models/period.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:plai/features/schedule/schedule_page.dart';
import 'package:plai/features/schedule/schedule_providers.dart';
import 'package:plai/features/timetable/timetable_providers.dart';
import 'package:plai/services/audio/complete_sound.dart';
import 'package:plai/services/notifications/notification_scheduler.dart';
import 'package:plai/services/notifications/notification_providers.dart';

class _Scheduler implements NotificationScheduler {
  _Scheduler(this.repo, {this.fail = false});
  final _FakeTaskRepo repo;
  final bool fail;
  final snapshots = <Set<DateTime>>[];
  final tasks = <Task>[];
  @override
  Future<void> scheduleTaskReminder(Task task) async {
    tasks.add(task);
    snapshots.add(repo.logsOf(task.id!));
    if (fail) throw StateError('notification failure');
  }

  @override
  dynamic noSuchMethod(Invocation call) =>
      throw UnsupportedError('${call.memberName}');
}

/// 内存版 ITaskRepository：widget 测试不触 sqflite 真 IO（fake-async 可跑）。
class _FakeTaskRepo implements ITaskRepository {
  final Map<int, Task> _byId = <int, Task>{};
  final Map<int, Set<DateTime>> _logs = <int, Set<DateTime>>{};
  int _nextId = 1;

  late final Task seeded = _seed();

  Task _seed() {
    final Task original = Task(
      title: '每日喝水',
      type: TaskType.daily,
      startDate: _day(DateTime.now()).subtract(const Duration(days: 1)),
      dueDate: _day(DateTime.now()).add(const Duration(days: 1)),
    );
    final int id = _nextId++;
    final Task withId = original.copyWith(id: id);
    _byId[id] = withId;
    return withId;
  }

  DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  Set<DateTime> logsOf(int id) =>
      Set<DateTime>.of(_logs[id] ?? const <DateTime>{});

  @override
  Future<List<Task>> getTasks({
    TaskType? type,
    bool? completed,
    DateTime? from,
    DateTime? to,
  }) async => _byId.values.toList();

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
    _logs.remove(id);
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
  Future<void> markDailyCompleted(int taskId, DateTime date) async {
    _logs.putIfAbsent(taskId, () => <DateTime>{}).add(_day(date));
  }

  @override
  Future<void> clearDailyCompleted(int taskId, DateTime date) async {
    _logs[taskId]?.remove(_day(date));
  }

  @override
  Future<bool> isDailyCompleted(int taskId, DateTime date) async =>
      (_logs[taskId] ?? const <DateTime>{}).contains(_day(date));

  @override
  Future<List<DateTime>> dailyLogsFor(int taskId) async {
    final List<DateTime> logs = (_logs[taskId] ?? const <DateTime>{}).toList()
      ..sort();
    return logs;
  }
}

class _BlockingRepo extends _FakeTaskRepo {
  final gate = Completer<void>();
  @override
  Future<void> markDailyCompleted(int taskId, DateTime date) async {
    await gate.future;
    await super.markDailyCompleted(taskId, date);
  }
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

/// 假完成提示音播放器：记录被点播的路径，不触真音频。
class _SoundRecorder implements CompletionSound {
  final List<String> paths = <String>[];

  @override
  Future<void> play(String path) async {
    paths.add(path);
  }
}

void main() {
  DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

  Widget wrap(_FakeTaskRepo repo, Task daily, {_Scheduler? scheduler}) {
    final TimetableStatusSettings settings = const TimetableStatusSettings(
      statusColorsEnabled: false,
      ongoingColor: '',
      upcomingColor: '',
      finishedColor: '',
      finishedTextFade: false,
      finishedTextThin: false,
      defaultCourseColor: '',
    );
    return ProviderScope(
      overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        notificationSchedulerProvider.overrideWithValue(
          scheduler ?? _Scheduler(repo),
        ),
        tasksProvider.overrideWith((ref) async => <Task>[daily]),
        todayCoursesProvider.overrideWith((ref) async => const <TodayCourse>[]),
        dayCoursesProvider.overrideWith(
          (ref, DateTime day) async => const <TodayCourse>[],
        ),
        periodsProvider.overrideWith((ref) async => const <Period>[]),
        timetableStatusSettingsProvider.overrideWith((ref) async => settings),
      ],
      child: const MaterialApp(home: SchedulePage()),
    );
  }

  testWidgets('今日无期限待办独立分组，不标今天到期', (tester) async {
    final repo = _FakeTaskRepo();
    await tester.pumpWidget(
      wrap(repo, Task(id: 42, title: '无期读书', type: TaskType.todo)),
    );
    await tester.pumpAndSettle();
    expect(find.text('无期限待办'), findsOneWidget);
    expect(find.text('无截止日期'), findsOneWidget);
    expect(find.text('无期读书'), findsOneWidget);
    expect(find.text('已逾期'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('今日页 daily 行：勾选→当天打卡入已完成；再点取消恢复', (WidgetTester tester) async {
    final _FakeTaskRepo repo = _FakeTaskRepo();
    final scheduler = _Scheduler(repo);
    final DateTime today = dayOf(DateTime.now());

    await tester.pumpWidget(wrap(repo, repo.seeded, scheduler: scheduler));
    await tester.pumpAndSettle();

    // 初始：daily 未打卡 → 在「今日」组，勾选框 false。
    expect(find.text('每日喝水'), findsOneWidget);
    expect(find.text('已完成'), findsNothing);
    Checkbox box = tester.widget<Checkbox>(find.byType(Checkbox));
    expect(box.value, isFalse);

    // 勾上：打卡记录写入，行挪入「已完成」，勾选框 true；task.completed 不被置真。
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();

    expect(repo.logsOf(repo.seeded.id!), contains(today));
    expect(repo.seeded.completed, isFalse);
    expect(find.text('已完成'), findsOneWidget);
    box = tester.widget<Checkbox>(find.byType(Checkbox));
    expect(box.value, isTrue);

    // 再点：取消该天打卡，行回「今日」。
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();

    expect(repo.logsOf(repo.seeded.id!), isNot(contains(today)));
    expect(find.text('已完成'), findsNothing);
    box = tester.widget<Checkbox>(find.byType(Checkbox));
    expect(box.value, isFalse);
    expect(tester.takeException(), isNull);
    expect(scheduler.snapshots, [
      <DateTime>{today},
      <DateTime>{},
    ]);
    expect(scheduler.tasks.every((task) => !task.completed), isTrue);
  });

  testWidgets('通知重排失败仍显示已打卡，撤销日志也保持一致', (tester) async {
    final repo = _FakeTaskRepo();
    final scheduler = _Scheduler(repo, fail: true);
    await tester.pumpWidget(wrap(repo, repo.seeded, scheduler: scheduler));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 100));
    expect(repo.logsOf(repo.seeded.id!), contains(dayOf(DateTime.now())));
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    expect(find.text('打卡记录已保存，但提醒更新失败，请稍后重试'), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(repo.logsOf(repo.seeded.id!), isEmpty);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    expect(scheduler.snapshots.length, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  for (final offset in [-1, 1]) {
    testWidgets('修改非当天打卡也在日志保存后重排：$offset', (tester) async {
      final repo = _FakeTaskRepo();
      final scheduler = _Scheduler(repo);
      final day = dayOf(DateTime.now()).add(Duration(days: offset));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            taskRepositoryProvider.overrideWithValue(repo),
            notificationSchedulerProvider.overrideWithValue(scheduler),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (_, ref, _) => TextButton(
                onPressed: () => toggleDailyCompleted(
                  ref,
                  repo.seeded,
                  day,
                  playSound: false,
                ),
                child: const Text('toggle'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('toggle'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('toggle'));
      await tester.pumpAndSettle();
      expect(scheduler.snapshots, [
        <DateTime>{day},
        <DateTime>{},
      ]);
      expect((await repo.getTaskById(repo.seeded.id!))!.completed, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('保存期间离开页面仍重排提醒，不访问已销毁ref', (tester) async {
    final repo = _BlockingRepo();
    final scheduler = _Scheduler(repo);
    final day = dayOf(DateTime.now());
    Future<void>? pending;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          taskRepositoryProvider.overrideWithValue(repo),
          notificationSchedulerProvider.overrideWithValue(scheduler),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (_, ref, _) => TextButton(
              onPressed: () => pending = toggleDailyCompleted(
                ref,
                repo.seeded,
                day,
                playSound: false,
              ),
              child: const Text('toggle'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('toggle'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    repo.gate.complete();
    await tester.pump();
    await pending;
    expect(scheduler.snapshots, [
      <DateTime>{day},
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('每日打卡勾上完成 → 播放设置好的完成提示音一次；再取消不播', (WidgetTester tester) async {
    final _FakeTaskRepo repo = _FakeTaskRepo();
    final _SoundRecorder sound = _SoundRecorder();
    final _FakeSettings settings = _FakeSettings(<String, String>{
      NotificationSettingsKeys.completeSound: '/snd/complete.mp3',
    });
    final DateTime today = dayOf(DateTime.now());

    await tester.pumpWidget(_wrapWithSound(repo, settings, sound));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Checkbox)); // 勾上（完成）
    await tester.pumpAndSettle();
    expect(sound.paths, <String>['/snd/complete.mp3']);

    await tester.tap(find.byType(Checkbox)); // 取消该天打卡（不是完成，不播）
    await tester.pumpAndSettle();
    expect(sound.paths, <String>['/snd/complete.mp3']);
    expect(tester.takeException(), isNull);
    expect(repo.logsOf(repo.seeded.id!), isNot(contains(today)));
  });

  testWidgets('未设置完成提示音时勾选完成不播放', (WidgetTester tester) async {
    final _FakeTaskRepo repo = _FakeTaskRepo();
    final _SoundRecorder sound = _SoundRecorder();
    final _FakeSettings settings = _FakeSettings(); // complete_sound 为空

    await tester.pumpWidget(_wrapWithSound(repo, settings, sound));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(sound.paths, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

/// 今日页 + 注入假设置/假完成音播放器（勾选完成走 [toggleDailyCompleted]）。
Widget _wrapWithSound(
  _FakeTaskRepo repo,
  _FakeSettings settings,
  _SoundRecorder sound,
) {
  final Task daily = repo.seeded;
  final TimetableStatusSettings statusSettings = const TimetableStatusSettings(
    statusColorsEnabled: false,
    ongoingColor: '',
    upcomingColor: '',
    finishedColor: '',
    finishedTextFade: false,
    finishedTextThin: false,
    defaultCourseColor: '',
  );
  return ProviderScope(
    overrides: [
      taskRepositoryProvider.overrideWithValue(repo),
      notificationSchedulerProvider.overrideWithValue(_Scheduler(repo)),
      tasksProvider.overrideWith((ref) async => <Task>[daily]),
      todayCoursesProvider.overrideWith((ref) async => const <TodayCourse>[]),
      dayCoursesProvider.overrideWith(
        (ref, DateTime day) async => const <TodayCourse>[],
      ),
      periodsProvider.overrideWith((ref) async => const <Period>[]),
      timetableStatusSettingsProvider.overrideWith(
        (ref) async => statusSettings,
      ),
      settingsRepositoryProvider.overrideWithValue(settings),
      completionSoundPlayerProvider.overrideWithValue(sound),
    ],
    child: const MaterialApp(home: SchedulePage()),
  );
}
