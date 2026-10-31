import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/task.dart';

import 'test_helpers.dart';

void main() {
  late TestData data;

  setUp(() async {
    data = await TestData.create();
  });

  tearDown(() async {
    await data.db.close();
  });

  test('Task CRUD 往返一致（含所有字段）', () async {
    final repo = data.tasks;
    final task = Task(
      title: '交高数作业',
      description: '第 3 章习题',
      type: TaskType.todo,
      dueDate: DateTime(2026, 10, 1),
      dueTime: '23:59',
      priority: Priority.important,
      remindOffsetMin: 30,
      remindDate: DateTime(2026, 10, 1, 23, 29),
    );
    final id = await repo.insertTask(task);

    final fetched = await repo.getTaskById(id);
    expect(fetched, task.copyWith(id: id));

    await repo.updateTask(task.copyWith(id: id, completed: true, completedAt: DateTime(2026, 10, 1, 20)));
    final updated = await repo.getTaskById(id);
    expect(updated!.completed, isTrue);
    expect(updated.completedAt, isNotNull);

    expect(await repo.deleteTask(id), 1);
    expect(await repo.getTaskById(id), isNull);
  });

  test('insertTask 未指定 createdAt 时自动填当前时间', () async {
    final repo = data.tasks;
    final id = await repo.insertTask(
      Task(title: '背单词', type: TaskType.todo, dueDate: DateTime(2026, 9, 5)),
    );
    final fetched = await repo.getTaskById(id);
    expect(fetched!.createdAt, isNotNull);
  });

  test('getTasks 支持类型/完成/日期范围过滤', () async {
    final repo = data.tasks;
    await repo.insertTask(Task(title: '会议', type: TaskType.scheduled, dueDate: DateTime(2026, 9, 1)));
    await repo.insertTask(Task(title: '作业A', type: TaskType.todo, dueDate: DateTime(2026, 9, 2)));
    await repo.insertTask(Task(title: '作业B', type: TaskType.todo, dueDate: DateTime(2026, 9, 5)));

    expect(await repo.getTasks(type: TaskType.todo), hasLength(2));
    expect(await repo.getTasks(type: TaskType.scheduled), hasLength(1));
    expect(await repo.getTasks(completed: false), hasLength(3));
    expect(
      await repo.getTasks(from: DateTime(2026, 9, 3), to: DateTime(2026, 9, 5)),
      hasLength(1),
    );
  });

  test('setCompleted 标记完成并记录/清空完成时间', () async {
    final repo = data.tasks;
    final id = await repo.insertTask(
      Task(title: '项目截止', type: TaskType.todo, dueDate: DateTime(2026, 9, 10)),
    );

    expect(await repo.setCompleted(id, true), 1);
    var task = await repo.getTaskById(id);
    expect(task!.completed, isTrue);
    expect(task.completedAt, isNotNull);

    expect(await repo.setCompleted(id, false), 1);
    task = await repo.getTaskById(id);
    expect(task!.completed, isFalse);
    expect(task.completedAt, isNull);
  });

  test('新类型 daily/span 的 startDate 往返一致；scheduled/todo 为空', () async {
    final repo = data.tasks;
    final daily = Task(
      title: '背单词',
      type: TaskType.daily,
      startDate: DateTime(2026, 9, 1),
      dueDate: DateTime(2026, 9, 30),
    );
    final span = Task(
      title: '毕业设计开题',
      type: TaskType.span,
      startDate: DateTime(2026, 9, 10),
      dueDate: DateTime(2026, 10, 15),
    );
    final dailyId = await repo.insertTask(daily);
    final spanId = await repo.insertTask(span);
    expect(await repo.getTaskById(dailyId), daily.copyWith(id: dailyId));
    expect(await repo.getTaskById(spanId), span.copyWith(id: spanId));

    // 老类型 startDate 为空（默认值）。
    final oldId = await repo.insertTask(
      Task(title: '旧待办', type: TaskType.todo, dueDate: DateTime(2026, 9, 5)),
    );
    expect((await repo.getTaskById(oldId))!.startDate, isNull);

    // 按新类型过滤。
    expect(await repo.getTasks(type: TaskType.daily), hasLength(1));
    expect(await repo.getTasks(type: TaskType.span), hasLength(1));
    expect(await repo.getTasks(type: TaskType.scheduled), isEmpty);
  });

  test('每日打卡：标记/查询/取消/列表，删任务级联清记录', () async {
    final repo = data.tasks;
    final id = await repo.insertTask(
      Task(
        title: '晨跑',
        type: TaskType.daily,
        startDate: DateTime(2026, 9, 1),
        dueDate: DateTime(2026, 9, 30),
      ),
    );
    final d1 = DateTime(2026, 9, 2);
    final d2 = DateTime(2026, 9, 5);

    expect(await repo.isDailyCompleted(id, d1), isFalse);

    await repo.markDailyCompleted(id, d1);
    await repo.markDailyCompleted(id, d2);
    expect(await repo.isDailyCompleted(id, d1), isTrue);
    expect(await repo.dailyLogsFor(id), [d1, d2]);

    // 幂等：重复标记不产生新记录。
    await repo.markDailyCompleted(id, d1);
    expect(await repo.dailyLogsFor(id), hasLength(2));

    // 取消一天。
    await repo.clearDailyCompleted(id, d1);
    expect(await repo.isDailyCompleted(id, d1), isFalse);
    expect(await repo.dailyLogsFor(id), [d2]);

    // 删任务 → daily logs 级联清空。
    expect(await repo.deleteTask(id), 1);
    expect(await repo.dailyLogsFor(id), isEmpty);
    expect(await repo.isDailyCompleted(id, d2), isFalse);
  });

  test('daily 的每日提醒时刻 daily_remind_time 往返一致；可更新/清空', () async {
    final repo = data.tasks;
    final id = await repo.insertTask(
      Task(
        title: '睡前背单词',
        type: TaskType.daily,
        startDate: DateTime(2026, 9, 1),
        dueDate: DateTime(2026, 9, 30),
        dailyRemindTime: '21:30',
      ),
    );
    expect((await repo.getTaskById(id))!.dailyRemindTime, '21:30');

    // 更新为其他时刻。
    final Task updated = (await repo.getTaskById(id))!.copyWith(dailyRemindTime: '06:00');
    await repo.updateTask(updated);
    expect((await repo.getTaskById(id))!.dailyRemindTime, '06:00');

    // 全量写入空 → 清除（copyWith 保留语义，清空走全量 Task 构造）。
    final Task cleared = Task(
      id: id,
      title: '睡前背单词',
      type: TaskType.daily,
      startDate: DateTime(2026, 9, 1),
      dueDate: DateTime(2026, 9, 30),
      dailyRemindTime: null,
      createdAt: updated.createdAt,
    );
    await repo.updateTask(cleared);
    expect((await repo.getTaskById(id))!.dailyRemindTime, isNull);

    // 非 daily 类型恒无该字段（默认空）。
    final todoId = await repo.insertTask(
      Task(title: '旧待办', type: TaskType.todo, dueDate: DateTime(2026, 9, 5)),
    );
    expect((await repo.getTaskById(todoId))!.dailyRemindTime, isNull);
  });

  test('提醒「每天 / 不重复」字段 reminder_repeat / remind_once_at 往返一致', () async {
    final repo = data.tasks;
    final DateTime onceAt = DateTime(2026, 11, 2, 9, 30);

    final int dailyId = await repo.insertTask(Task(
      title: '每天提醒',
      type: TaskType.todo,
      dueDate: DateTime(2026, 11, 5),
      dailyRemindTime: '07:15',
      reminderRepeat: ReminderRepeat.daily,
    ));
    final Task daily = (await repo.getTaskById(dailyId))!;
    expect(daily.reminderRepeat, ReminderRepeat.daily);
    expect(daily.dailyRemindTime, '07:15');
    expect(daily.remindOnceAt, isNull);

    final int onceId = await repo.insertTask(Task(
      title: '一次性提醒',
      type: TaskType.todo,
      dueDate: DateTime(2026, 11, 5),
      reminderRepeat: ReminderRepeat.once,
      remindOnceAt: onceAt,
    ));
    final Task once = (await repo.getTaskById(onceId))!;
    expect(once.reminderRepeat, ReminderRepeat.once);
    expect(once.remindOnceAt, onceAt);
    expect(once.dailyRemindTime, isNull);

    // 老数据两列为 null：读出来仍是 null，调度侧按 daily_remind_time 兜底。
    final int legacyId = await repo.insertTask(
      Task(title: '老任务', type: TaskType.todo, dueDate: DateTime(2026, 11, 5)),
    );
    final Task legacy = (await repo.getTaskById(legacyId))!;
    expect(legacy.reminderRepeat, isNull);
    expect(legacy.remindOnceAt, isNull);
  });

  test('Task.toJson/fromJson 往返新提醒字段，未知 repeat code 容错为 null', () {
    final Task task = Task(
      title: '交报告',
      type: TaskType.span,
      startDate: DateTime(2026, 11, 1),
      dueDate: DateTime(2026, 11, 3),
      reminderRepeat: ReminderRepeat.once,
      remindOnceAt: DateTime(2026, 11, 2, 8, 5),
    );
    final Task back = Task.fromJson(task.toJson());
    expect(back.reminderRepeat, ReminderRepeat.once);
    expect(back.remindOnceAt, DateTime(2026, 11, 2, 8, 5));

    // 老备份文件没有这两个键 → null，不抛异常。
    final Map<String, Object?> legacyJson = task.toJson()
      ..remove('reminderRepeat')
      ..remove('remindOnceAt');
    final Task legacy = Task.fromJson(legacyJson);
    expect(legacy.reminderRepeat, isNull);
    expect(legacy.remindOnceAt, isNull);

    // 手改文件写脏 code → 容错为 null。
    expect(ReminderRepeat.tryFromCode('weekly'), isNull);
    expect(ReminderRepeat.tryFromCode(''), isNull);
  });
}
