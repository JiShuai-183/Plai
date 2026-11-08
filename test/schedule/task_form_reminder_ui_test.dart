import 'package:flutter/cupertino.dart';
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
import 'package:plai/features/timetable/format.dart';
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

DateTime todayOnly() {
  final DateTime now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

Task todoTask({
  DateTime? dueDate,
  String? dailyRemindTime,
  TaskType type = TaskType.todo,
}) {
  return Task(
    title: '复习',
    type: type,
    dueDate: dueDate ?? todayOnly(),
    startDate: type == TaskType.span ? (dueDate ?? todayOnly()) : null,
    dailyRemindTime: dailyRemindTime,
  );
}

void main() {
  /// 拉高测试视口：表单 ListView 整列在屏内，避免懒加载导致底部 tile 未构建。
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget wrap(_FakeTaskRepo repo, {Task? task, DateTime? initialDate}) {
    return ProviderScope(
      overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        notificationSchedulerProvider.overrideWithValue(_FakeScheduler()),
        courseOptionsProvider.overrideWith(
          (ref) async => const <(int, String)>[],
        ),
      ],
      child: MaterialApp(
        home: TaskFormPage(task: task, initialDate: initialDate),
      ),
    );
  }

  Future<void> pumpForm(
    WidgetTester tester,
    _FakeTaskRepo repo, {
    Task? task,
    DateTime? initialDate,
  }) async {
    await tester.pumpWidget(wrap(repo, task: task, initialDate: initialDate));
    await tester.pumpAndSettle();
  }

  Future<void> toggleReminder(WidgetTester tester) async {
    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
  }

  Future<void> selectRepeat(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  Future<void> openReminderSheet(WidgetTester tester) async {
    await tester.ensureVisible(find.text('提醒时刻'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提醒时刻'));
    await tester.pumpAndSettle();
  }

  FilledButton sheetConfirm(WidgetTester tester) {
    return tester.widget<FilledButton>(
      find.byKey(const Key('reminder_sheet_confirm')),
    );
  }

  void jumpPicker(WidgetTester tester, String key, int item) {
    final CupertinoPicker picker = tester.widget<CupertinoPicker>(
      find.byKey(Key(key)),
    );
    (picker.scrollController as FixedExtentScrollController).jumpToItem(item);
  }

  testWidgets('新建待办默认无截止，切daily默认今天起长期', (tester) async {
    useTallSurface(tester);
    final repo = _FakeTaskRepo();
    await pumpForm(tester, repo);
    expect(find.text('无截止日期'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, '长期读书');
    await tester.tap(find.byType(DropdownButtonFormField<TaskType>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(TaskType.daily.label).last);
    await tester.pumpAndSettle();
    expect(find.text('长期'), findsOneWidget);
    await tester.tap(find.text('添加任务'));
    await tester.pumpAndSettle();
    final saved = (await repo.getTasks()).single;
    expect(saved.type, TaskType.daily);
    expect(saved.startDate, todayOnly());
    expect(saved.dueDate, isNull);
  });

  testWidgets('新建待办保存真实null截止', (tester) async {
    useTallSurface(tester);
    final repo = _FakeTaskRepo();
    await pumpForm(tester, repo);
    await tester.enterText(find.byType(TextFormField).first, '无期读书');
    await tester.tap(find.text('添加任务'));
    await tester.pumpAndSettle();
    expect((await repo.getTasks()).single.dueDate, isNull);
  });

  testWidgets('已有日期切换类型再切回保留，主动清空保存null', (tester) async {
    useTallSurface(tester);
    final repo = _FakeTaskRepo();
    final seeded = repo.seed(todoTask(dueDate: DateTime(2030, 3, 4)));
    await pumpForm(tester, repo, task: seeded);
    await tester.tap(find.byType(DropdownButtonFormField<TaskType>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(TaskType.daily.label).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<TaskType>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(TaskType.todo.label).last);
    await tester.pumpAndSettle();
    expect(find.text(formatFullDate(seeded.dueDate!)), findsOneWidget);
    await tester.tap(find.byTooltip('清除截止日期'));
    await tester.pumpAndSettle();
    expect(find.text('无截止日期'), findsOneWidget);
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();
    expect((await repo.getTaskById(seeded.id!))!.dueDate, isNull);
  });

  testWidgets('span编辑保存保留明确截止时刻', (tester) async {
    useTallSurface(tester);
    final repo = _FakeTaskRepo();
    final seeded = repo.seed(
      Task(
        title: '准备考试',
        type: TaskType.span,
        startDate: todayOnly(),
        dueDate: todayOnly().add(const Duration(days: 3)),
        dueTime: '18:30',
      ),
    );
    await pumpForm(tester, repo, task: seeded);
    expect(find.text('18:30'), findsOneWidget);
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();
    expect((await repo.getTaskById(seeded.id!))!.dueTime, '18:30');
  });

  testWidgets('三种类型显示「提醒」开关；daily 保持旧「每日提醒时刻」行', (WidgetTester tester) async {
    useTallSurface(tester);
    for (final TaskType type in [
      TaskType.todo,
      TaskType.scheduled,
      TaskType.span,
    ]) {
      await tester.pumpWidget(const SizedBox());
      final _FakeTaskRepo repo = _FakeTaskRepo();
      await pumpForm(tester, repo, task: todoTask(type: type));
      expect(find.byType(SwitchListTile), findsOneWidget, reason: 'type=$type');
      expect(find.text('提醒'), findsOneWidget, reason: 'type=$type');
      // 未开启时只有开关，不出现重复方式/时刻行。
      expect(find.text('重复方式'), findsNothing, reason: 'type=$type');
      expect(find.text('提醒时刻'), findsNothing, reason: 'type=$type');
      expect(find.text('每日提醒时刻'), findsNothing, reason: 'type=$type');
    }

    // daily 完全不动：旧行 + 拨盘，无新开关。
    await tester.pumpWidget(const SizedBox());
    final _FakeTaskRepo repo = _FakeTaskRepo();
    final Task daily = repo.seed(
      Task(
        title: '每日喝水',
        type: TaskType.daily,
        startDate: todayOnly(),
        dueDate: todayOnly().add(const Duration(days: 6)),
        dailyRemindTime: '07:00',
      ),
    );
    await pumpForm(tester, repo, task: daily);
    expect(find.text('每日提醒时刻'), findsOneWidget);
    expect(find.text('每天 07:00'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets('开关显隐重复方式与提醒时刻；关闭重开保留上次值', (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeTaskRepo repo = _FakeTaskRepo();
    final Task seeded = repo.seed(todoTask(dailyRemindTime: '09:30'));
    await pumpForm(tester, repo, task: seeded);

    // 编辑已有提醒：开关默认开。
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    expect(find.text('重复方式'), findsOneWidget);
    expect(find.text('提醒时刻'), findsOneWidget);
    expect(find.text('每天 09:30'), findsOneWidget);

    await toggleReminder(tester);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    expect(find.text('重复方式'), findsNothing);
    expect(find.text('提醒时刻'), findsNothing);

    await toggleReminder(tester);
    expect(find.text('每天 09:30'), findsOneWidget);
  });

  testWidgets('每天=2 轮（时/分）；不重复=3 轮（日期/时/分）', (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeTaskRepo repo = _FakeTaskRepo();
    await pumpForm(tester, repo);
    await toggleReminder(tester);

    await openReminderSheet(tester);
    expect(find.text('提醒时刻（每天）'), findsOneWidget);
    expect(find.byType(CupertinoPicker), findsNWidgets(2));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await selectRepeat(tester, '不重复');
    await openReminderSheet(tester);
    expect(find.text('提醒时刻（不重复）'), findsOneWidget);
    expect(find.byType(CupertinoPicker), findsNWidgets(3));
    expect(find.byKey(const Key('reminder_day_picker')), findsOneWidget);
    expect(find.byKey(const Key('reminder_hour_picker')), findsOneWidget);
    expect(find.byKey(const Key('reminder_minute_picker')), findsOneWidget);
  });

  testWidgets('不重复默认=任务日期 08:00', (WidgetTester tester) async {
    useTallSurface(tester);
    final DateTime future = todayOnly().add(const Duration(days: 10));
    final _FakeTaskRepo repo = _FakeTaskRepo();
    final Task seeded = repo.seed(todoTask(dueDate: future));
    await pumpForm(tester, repo, task: seeded);

    await toggleReminder(tester);
    await selectRepeat(tester, '不重复');
    expect(find.text('${formatMonthDay(future)} 08:00'), findsOneWidget);
  });

  testWidgets('不重复默认：任务日期已过去 → 顺延到晚于现在', (WidgetTester tester) async {
    useTallSurface(tester);
    final DateTime past = todayOnly().subtract(const Duration(days: 10));
    final _FakeTaskRepo repo = _FakeTaskRepo();
    final Task seeded = repo.seed(todoTask(dueDate: past));
    await pumpForm(tester, repo, task: seeded);

    await toggleReminder(tester);
    await selectRepeat(tester, '不重复');
    // 「提醒时刻」副标题不落在过去日期上（表单「日期」行仍显示任务的过去日期）。
    final ListTile reminderTile = tester.widget<ListTile>(
      find.ancestor(of: find.text('提醒时刻'), matching: find.byType(ListTile)),
    );
    final String reminderSubtitle = (reminderTile.subtitle! as Text).data!;
    expect(reminderSubtitle, isNot(contains(formatMonthDay(past))));

    // 弹层初始值可确定，即所选时刻晚于 now（确定按钮的启用条件正是该判断）。
    await openReminderSheet(tester);
    expect(sheetConfirm(tester).onPressed, isNotNull);
    expect(find.textContaining(formatFullDate(todayOnly())), findsWidgets);
  });

  testWidgets('日期下限今天；跨年条目带（次年）标注与完整年份', (WidgetTester tester) async {
    useTallSurface(tester);
    final DateTime today = todayOnly();
    final DateTime last = today.add(const Duration(days: 365));
    // 极少数闰年 1/1 边界下 365 天仍在本年，此时范围内不存在次年日期。
    if (last.year == today.year) return;

    final _FakeTaskRepo repo = _FakeTaskRepo();
    final Task seeded = repo.seed(todoTask(dueDate: last));
    await pumpForm(tester, repo, task: seeded);

    await toggleReminder(tester);
    await selectRepeat(tester, '不重复');
    expect(find.text('${formatMonthDay(last)}（次年） 08:00'), findsOneWidget);

    await openReminderSheet(tester);
    expect(find.textContaining('${last.year}年'), findsWidgets);

    // 日期下限今天：滚到最上一条仍是今天，不出现昨天。
    jumpPicker(tester, 'reminder_day_picker', 0);
    await tester.pumpAndSettle();
    expect(find.textContaining(formatFullDate(today)), findsWidgets);
    expect(
      find.textContaining(
        formatFullDate(today.subtract(const Duration(days: 1))),
      ),
      findsNothing,
    );
  });

  testWidgets('选中时刻不晚于现在 → 确定禁用 + 提示', (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeTaskRepo repo = _FakeTaskRepo();
    final Task seeded = repo.seed(todoTask(dueDate: todayOnly()));
    await pumpForm(tester, repo, task: seeded);

    await toggleReminder(tester);
    await selectRepeat(tester, '不重复');
    await openReminderSheet(tester);

    // 日期滚到今天、时分滚到 00:00，必然不晚于 now。
    jumpPicker(tester, 'reminder_day_picker', 0);
    await tester.pumpAndSettle();
    jumpPicker(tester, 'reminder_hour_picker', 0);
    await tester.pumpAndSettle();
    jumpPicker(tester, 'reminder_minute_picker', 0);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('reminder_sheet_hint')), findsOneWidget);
    expect(find.text('请选择晚于现在的时间'), findsOneWidget);
    expect(sheetConfirm(tester).onPressed, isNull);
  });

  testWidgets('每天：滚轮选时分保留并保存；切「不重复」保留已选时分', (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeTaskRepo repo = _FakeTaskRepo();
    await pumpForm(tester, repo);

    await tester.enterText(find.byType(TextFormField).first, '测试任务');
    await toggleReminder(tester);
    await openReminderSheet(tester);
    jumpPicker(tester, 'reminder_hour_picker', 9);
    await tester.pumpAndSettle();
    jumpPicker(tester, 'reminder_minute_picker', 30);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.text('每天 09:30'), findsOneWidget);

    await selectRepeat(tester, '不重复');
    expect(find.textContaining('09:30'), findsOneWidget);

    // 切回每天后用该时分保存。
    await selectRepeat(tester, '每天');
    await tester.tap(find.text('添加任务'));
    await tester.pumpAndSettle();

    final List<Task> saved = await repo.getTasks();
    expect(saved, hasLength(1));
    expect(saved.single.dailyRemindTime, '09:30');
  });

  testWidgets('取消滚轮弹层不改值', (WidgetTester tester) async {
    useTallSurface(tester);
    final _FakeTaskRepo repo = _FakeTaskRepo();
    await pumpForm(tester, repo);
    await toggleReminder(tester);
    expect(find.text('每天 08:00'), findsOneWidget);

    await openReminderSheet(tester);
    jumpPicker(tester, 'reminder_hour_picker', 15);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('每天 08:00'), findsOneWidget);
  });

  testWidgets('不重复 → 保存写入 remindOnceAt；编辑回填并保持 once；关闭开关即清除', (
    WidgetTester tester,
  ) async {
    useTallSurface(tester);
    // ① 新建：切「不重复」不再禁用保存，落库写 remindOnceAt + reminderRepeat。
    final _FakeTaskRepo repo = _FakeTaskRepo();
    await pumpForm(tester, repo);
    await tester.enterText(find.byType(TextFormField).first, '测试任务');
    await toggleReminder(tester);
    await selectRepeat(tester, '不重复');

    final FilledButton saveButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '添加任务'),
    );
    expect(saveButton.onPressed, isNotNull, reason: '阶段 2 起不应再禁用保存');

    await tester.tap(find.text('添加任务'));
    await tester.pumpAndSettle();

    final Task created = (await repo.getTasks()).single;
    expect(created.reminderRepeat, ReminderRepeat.once);
    expect(created.dailyRemindTime, isNull, reason: '不重复不写每日时刻');
    final DateTime at = created.remindOnceAt!;
    expect(at.isAfter(DateTime.now()), isTrue, reason: '默认值必须晚于现在');

    // ② 编辑回填：开关开、重复方式「不重复」、副标题是同一时刻。
    await tester.pumpWidget(const SizedBox());
    final _FakeTaskRepo repo2 = _FakeTaskRepo();
    final Task seeded = repo2.seed(created);
    await pumpForm(tester, repo2, task: seeded);
    final String crossYear = at.year == DateTime.now().year ? '' : '（次年）';
    final String label =
        '${formatMonthDay(at)}$crossYear '
        '${formatTimeOfDay(TimeOfDay(hour: at.hour, minute: at.minute))}';
    expect(find.text(label), findsOneWidget);
    expect(find.text('提醒时刻'), findsOneWidget);

    // 保存回填值不应改变语义。
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();
    final Task? kept = await repo2.getTaskById(seeded.id!);
    expect(kept!.reminderRepeat, ReminderRepeat.once);
    expect(kept.remindOnceAt, at);

    // ③ 编辑已有提醒 → 关闭开关 → 保存等价清除（两个字段都空）。
    await tester.pumpWidget(const SizedBox());
    final _FakeTaskRepo repo3 = _FakeTaskRepo();
    final Task dailySeeded = repo3.seed(todoTask(dailyRemindTime: '06:00'));
    await pumpForm(tester, repo3, task: dailySeeded);
    expect(find.text('每天 06:00'), findsOneWidget);

    await toggleReminder(tester);
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();

    final Task? cleared = await repo3.getTaskById(dailySeeded.id!);
    expect(cleared!.dailyRemindTime, isNull);
    expect(cleared.reminderRepeat, isNull);
    expect(cleared.remindOnceAt, isNull);
  });

  /// 溢出回归：窄屏 + 大字体下，表单与滚轮弹层均不得抛异常，按钮始终可见。
  Future<void> expectNoOverflow(
    WidgetTester tester, {
    required Size size,
    required double textScale,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final _FakeTaskRepo repo = _FakeTaskRepo();
    await pumpForm(tester, repo);
    expect(tester.takeException(), isNull, reason: '表单初始构建');

    await tester.scrollUntilVisible(
      find.byType(SwitchListTile),
      120,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '滚动到提醒开关');

    await toggleReminder(tester);
    expect(tester.takeException(), isNull, reason: '展开提醒区');

    await tester.scrollUntilVisible(
      find.text('提醒时刻'),
      120,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '滚动到提醒时刻');

    await openReminderSheet(tester);
    expect(tester.takeException(), isNull, reason: '每天滚轮弹层');
    expect(find.text('确定').hitTestable(), findsOneWidget);
    expect(find.text('取消').hitTestable(), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await selectRepeat(tester, '不重复');
    expect(tester.takeException(), isNull, reason: '切到不重复');
    await openReminderSheet(tester);
    expect(tester.takeException(), isNull, reason: '不重复滚轮弹层');
    expect(find.text('确定').hitTestable(), findsOneWidget);
    expect(find.text('取消').hitTestable(), findsOneWidget);
  }

  testWidgets('溢出回归：320×640 @1.5×', (WidgetTester tester) async {
    await expectNoOverflow(tester, size: const Size(320, 640), textScale: 1.5);
  });

  testWidgets('溢出回归：360×640 @2.0×', (WidgetTester tester) async {
    await expectNoOverflow(tester, size: const Size(360, 640), textScale: 2.0);
  });
}
