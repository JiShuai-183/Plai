import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/features/schedule/task_rules.dart';

void main() {
  group('compareTasks', () {
    test('逾期未完成置顶', () {
      final Task overdue = _task(
        title: '逾期',
        dueDate: DateTime(2026, 8, 30),
        dueTime: '09:00',
        completed: false,
      );
      final Task today = _task(
        title: '今日',
        dueDate: DateTime(2026, 8, 31),
        dueTime: '09:00',
        completed: false,
      );
      final DateTime now = DateTime(2026, 8, 31, 10, 0);
      expect(compareTasks(overdue, today, now: now), lessThan(0));
    });

    test('优先级紧急 > 重要 > 普通', () {
      final Task urgent = _task(title: '紧急', dueDate: DateTime(2026, 9, 1), priority: Priority.urgent);
      final Task normal = _task(title: '普通', dueDate: DateTime(2026, 9, 1), priority: Priority.normal);
      expect(compareTasks(urgent, normal), lessThan(0));
    });

    test('daily 按 startDate、span 按 dueDate、todo 按 dueDate 入序', () {
      final DateTime now = DateTime(2026, 8, 31, 12, 0);
      final Task daily = _task(
        title: '打卡',
        type: TaskType.daily,
        startDate: DateTime(2026, 9, 1),
        dueDate: DateTime(2026, 9, 30),
      );
      final Task todo = _task(
        title: '待办',
        dueDate: DateTime(2026, 9, 5),
      );
      final Task span = _task(
        title: '跨期',
        type: TaskType.span,
        startDate: DateTime(2026, 9, 3),
        dueDate: DateTime(2026, 9, 10),
      );
      // 均未逾期，按日期序键：daily(start 9/1) < todo(9/5) < span(due 9/10)。
      expect(compareTasks(daily, todo, now: now), lessThan(0));
      expect(compareTasks(todo, span, now: now), lessThan(0));
      expect(compareTasks(daily, span, now: now), lessThan(0));
    });

    test('daily 永不置顶逾期（不崩）', () {
      final Task daily = _task(
        title: '已过截止',
        type: TaskType.daily,
        startDate: DateTime(2026, 7, 1),
        dueDate: DateTime(2026, 7, 31),
        completed: false,
      );
      final Task todo = _task(
        title: '待办',
        dueDate: DateTime(2026, 8, 5),
      );
      final DateTime now = DateTime(2026, 9, 1);
      expect(compareTasks(todo, daily, now: now), lessThan(0));
      // 反序亦不抛。
      expect(compareTasks(daily, todo, now: now), greaterThan(0));
    });
  });

  group('isTaskOverdue', () {
    test('已完成后不再逾期', () {
      final Task done = _task(
        title: '完成',
        dueDate: DateTime(2026, 8, 29),
        completed: true,
      );
      expect(isTaskOverdue(done, now: DateTime(2026, 8, 31)), isFalse);
    });

    test('无时刻任务次日 0 点起算逾期', () {
      final Task t = _task(title: '无时刻', dueDate: DateTime(2026, 8, 30));
      expect(
          isTaskOverdue(t, now: DateTime(2026, 8, 31, 0, 0, 1)), isTrue);
      expect(
          isTaskOverdue(t, now: DateTime(2026, 8, 30, 23, 59, 59)), isFalse);
    });

    test('有时刻任务过点后逾期', () {
      final Task t = _task(
        title: '有时刻',
        dueDate: DateTime(2026, 8, 31),
        dueTime: '10:00',
      );
      expect(
          isTaskOverdue(t, now: DateTime(2026, 8, 31, 10, 0, 1)), isTrue);
      expect(isTaskOverdue(t, now: DateTime(2026, 8, 31, 9, 59)), isFalse);
    });

    test('span 未完成且过 dueDate 逾期', () {
      final Task span = _task(
        title: '跨期逾期',
        type: TaskType.span,
        startDate: DateTime(2026, 8, 25),
        dueDate: DateTime(2026, 8, 31),
        completed: false,
      );
      expect(
          isTaskOverdue(span, now: DateTime(2026, 9, 1, 0, 0, 1)), isTrue);
      expect(
          isTaskOverdue(span, now: DateTime(2026, 8, 31, 23, 59, 59)),
          isFalse);
      // 区间中段未到截止不算逾期。
      expect(isTaskOverdue(span, now: DateTime(2026, 8, 28, 12, 0)), isFalse);
    });

    test('span 已完成不过期；有 dueTime 到点即逾期', () {
      final Task done = _task(
        title: '跨期完成',
        type: TaskType.span,
        startDate: DateTime(2026, 8, 20),
        dueDate: DateTime(2026, 8, 31),
        completed: true,
      );
      expect(
          isTaskOverdue(done, now: DateTime(2026, 9, 1)), isFalse);
      final Task withTime = _task(
        title: '跨期有时刻',
        type: TaskType.span,
        startDate: DateTime(2026, 8, 20),
        dueDate: DateTime(2026, 8, 31),
        dueTime: '18:00',
        completed: false,
      );
      expect(
          isTaskOverdue(withTime, now: DateTime(2026, 8, 31, 18, 0, 1)),
          isTrue);
      expect(
          isTaskOverdue(withTime, now: DateTime(2026, 8, 31, 17, 59, 59)),
          isFalse);
    });

    test('daily 恒不逾期（已完成与未完成均 false）', () {
      final Task undone = _task(
        title: '打卡未完成',
        type: TaskType.daily,
        startDate: DateTime(2026, 7, 1),
        dueDate: DateTime(2026, 7, 31),
        completed: false,
      );
      final Task done = _task(
        title: '打卡完成',
        type: TaskType.daily,
        startDate: DateTime(2026, 7, 1),
        dueDate: DateTime(2026, 7, 31),
        completed: true,
      );
      expect(isTaskOverdue(undone, now: DateTime(2026, 9, 1)), isFalse);
      expect(isTaskOverdue(done, now: DateTime(2026, 9, 1)), isFalse);
    });
  });

  group('taskActiveOn', () {
    test('span 区间内活跃、区间外不活跃（day 带时刻亦按日判）', () {
      final Task span = _task(
        title: '跨期',
        type: TaskType.span,
        startDate: DateTime(2026, 9, 1),
        dueDate: DateTime(2026, 9, 5),
      );
      expect(taskActiveOn(span, DateTime(2026, 9, 1)), isTrue);
      expect(taskActiveOn(span, DateTime(2026, 9, 5)), isTrue);
      expect(taskActiveOn(span, DateTime(2026, 9, 3, 15, 30)), isTrue);
      expect(taskActiveOn(span, DateTime(2026, 8, 31)), isFalse);
      expect(taskActiveOn(span, DateTime(2026, 9, 6)), isFalse);
    });

    test('span 单日（startDate == dueDate）正常', () {
      final Task single = _task(
        title: '单日跨期',
        type: TaskType.span,
        startDate: DateTime(2026, 9, 3),
        dueDate: DateTime(2026, 9, 3),
      );
      expect(taskActiveOn(single, DateTime(2026, 9, 3)), isTrue);
      expect(taskActiveOn(single, DateTime(2026, 9, 2)), isFalse);
      expect(taskActiveOn(single, DateTime(2026, 9, 4)), isFalse);
    });

    test('span startDate > dueDate 非法区间不活跃（防御）', () {
      final Task bad = _task(
        title: '非法跨期',
        type: TaskType.span,
        startDate: DateTime(2026, 9, 6),
        dueDate: DateTime(2026, 9, 3),
      );
      expect(taskActiveOn(bad, DateTime(2026, 9, 3)), isFalse);
      expect(taskActiveOn(bad, DateTime(2026, 9, 6)), isFalse);
      expect(taskActiveOn(bad, DateTime(2026, 9, 5)), isFalse);
    });

    test('span startDate 缺失视同单日（dueDate）', () {
      final Task noStart = _task(
        title: '无起点跨期',
        type: TaskType.span,
        dueDate: DateTime(2026, 9, 3),
      );
      expect(taskActiveOn(noStart, DateTime(2026, 9, 3)), isTrue);
      expect(taskActiveOn(noStart, DateTime(2026, 9, 4)), isFalse);
    });

    test('todo/scheduled 仅 dueDate 当天活跃', () {
      final Task todo = _task(
        title: '待办',
        dueDate: DateTime(2026, 9, 3),
        dueTime: '10:00',
      );
      expect(taskActiveOn(todo, DateTime(2026, 9, 3, 23, 59)), isTrue);
      expect(taskActiveOn(todo, DateTime(2026, 9, 2)), isFalse);
      expect(taskActiveOn(todo, DateTime(2026, 9, 4)), isFalse);
    });

    test('daily 区间内活跃、区间外 false', () {
      final Task daily = _task(
        title: '打卡',
        type: TaskType.daily,
        startDate: DateTime(2026, 9, 1),
        dueDate: DateTime(2026, 9, 5),
      );
      expect(taskActiveOn(daily, DateTime(2026, 9, 1)), isTrue);
      expect(taskActiveOn(daily, DateTime(2026, 9, 5)), isTrue);
      expect(taskActiveOn(daily, DateTime(2026, 9, 3, 8, 30)), isTrue);
      expect(taskActiveOn(daily, DateTime(2026, 8, 31)), isFalse);
      expect(taskActiveOn(daily, DateTime(2026, 9, 6)), isFalse);
    });
  });

  group('isDailyOpenOn', () {
    test('daily 区间内 open、含端点、区间外 false（带时刻按日判）', () {
      final Task daily = _task(
        title: '打卡',
        type: TaskType.daily,
        startDate: DateTime(2026, 9, 1),
        dueDate: DateTime(2026, 9, 5),
      );
      expect(isDailyOpenOn(daily, DateTime(2026, 9, 1)), isTrue);
      expect(isDailyOpenOn(daily, DateTime(2026, 9, 5)), isTrue);
      expect(isDailyOpenOn(daily, DateTime(2026, 9, 3, 23, 59)), isTrue);
      expect(isDailyOpenOn(daily, DateTime(2026, 8, 31)), isFalse);
      expect(isDailyOpenOn(daily, DateTime(2026, 9, 6)), isFalse);
    });

    test('daily startDate>dueDate 非法区间恒 false（防御）', () {
      final Task bad = _task(
        title: '非法打卡',
        type: TaskType.daily,
        startDate: DateTime(2026, 9, 6),
        dueDate: DateTime(2026, 9, 3),
      );
      expect(isDailyOpenOn(bad, DateTime(2026, 9, 5)), isFalse);
      expect(isDailyOpenOn(bad, DateTime(2026, 9, 6)), isFalse);
    });

    test('非 daily 类型返回 false', () {
      final Task todo = _task(
        title: '待办',
        startDate: DateTime(2026, 9, 1),
        dueDate: DateTime(2026, 9, 5),
      );
      expect(isDailyOpenOn(todo, DateTime(2026, 9, 3)), isFalse);
    });
  });

  group('isDailyDoneOn', () {
    test('某日完成记录命中（doneDates 带时刻亦按自然日归一）', () {
      final Task daily = _task(
        title: '打卡',
        type: TaskType.daily,
        startDate: DateTime(2026, 9, 1),
        dueDate: DateTime(2026, 9, 30),
      );
      final Set<DateTime> doneDates = {
        DateTime(2026, 9, 2, 8, 15),
        DateTime(2026, 9, 3, 21, 40),
      };
      expect(
          isDailyDoneOn(daily, DateTime(2026, 9, 2, 23, 59),
              doneDates: doneDates),
          isTrue);
      expect(isDailyDoneOn(daily, DateTime(2026, 9, 3), doneDates: doneDates),
          isTrue);
      expect(isDailyDoneOn(daily, DateTime(2026, 9, 4), doneDates: doneDates),
          isFalse);
      expect(isDailyDoneOn(daily, DateTime(2026, 9, 1), doneDates: doneDates),
          isFalse);
    });

    test('空 doneDates 无完成', () {
      final Task daily = _task(
        title: '打卡',
        type: TaskType.daily,
        startDate: DateTime(2026, 9, 1),
        dueDate: DateTime(2026, 9, 30),
      );
      expect(
          isDailyDoneOn(daily, DateTime(2026, 9, 3),
              doneDates: <DateTime>{}),
          isFalse);
    });

    test('仅因同一自然日命中，不误判相邻日', () {
      final Task daily = _task(
        title: '打卡',
        type: TaskType.daily,
        startDate: DateTime(2026, 9, 1),
        dueDate: DateTime(2026, 9, 30),
      );
      expect(
          isDailyDoneOn(daily, DateTime(2026, 9, 10),
              doneDates: {DateTime(2026, 9, 10, 0, 0)}),
          isTrue);
      expect(
          isDailyDoneOn(daily, DateTime(2026, 9, 9),
              doneDates: {DateTime(2026, 9, 10, 0, 0)}),
          isFalse);
      expect(
          isDailyDoneOn(daily, DateTime(2026, 9, 11),
              doneDates: {DateTime(2026, 9, 10, 23, 59)}),
          isFalse);
    });
  });

  group('computeRemindAt', () {
    test('不提醒返回 null', () {
      final Task t = _task(
        title: '无提醒',
        dueDate: DateTime(2026, 9, 1),
        dueTime: '10:00',
        remindOffsetMin: null,
      );
      expect(computeRemindAt(t), isNull);
    });

    test('准时（-1）= 截止时刻', () {
      final Task t = _task(
        title: '准时',
        dueDate: DateTime(2026, 9, 1),
        dueTime: '10:00',
        remindOffsetMin: -1,
      );
      expect(computeRemindAt(t), DateTime(2026, 9, 1, 10, 0));
    });

    test('提前 15 分钟', () {
      final Task t = _task(
        title: '提前',
        dueDate: DateTime(2026, 9, 1),
        dueTime: '10:00',
        remindOffsetMin: 15,
      );
      expect(computeRemindAt(t), DateTime(2026, 9, 1, 9, 45));
    });

    test('无时刻视为当天 00:00', () {
      final Task t = _task(
        title: '无时刻提醒',
        dueDate: DateTime(2026, 9, 1),
        remindOffsetMin: -1,
      );
      expect(computeRemindAt(t), DateTime(2026, 9, 1, 0, 0));
    });

    test('daily/span 无提醒 UI，恒返回 null（含已设 offset）', () {
      final Task daily = _task(
        title: '打卡',
        type: TaskType.daily,
        startDate: DateTime(2026, 9, 1),
        dueDate: DateTime(2026, 9, 30),
        dueTime: '10:00',
        remindOffsetMin: 15,
      );
      final Task span = _task(
        title: '跨期',
        type: TaskType.span,
        startDate: DateTime(2026, 9, 1),
        dueDate: DateTime(2026, 9, 10),
        dueTime: '10:00',
        remindOffsetMin: -1,
      );
      expect(computeRemindAt(daily), isNull);
      expect(computeRemindAt(span), isNull);
    });
  });

  group('taskDeadline', () {
    test('无时刻默认当天 23:59:59', () {
      final Task t = _task(title: 'x', dueDate: DateTime(2026, 9, 1));
      expect(taskDeadline(t), DateTime(2026, 9, 1, 23, 59, 59));
    });

    test('有时刻按时刻', () {
      final Task t = _task(
        title: 'x',
        dueDate: DateTime(2026, 9, 1),
        dueTime: '12:30',
      );
      expect(taskDeadline(t), DateTime(2026, 9, 1, 12, 30, 0));
    });
  });

  group('dateSortKey', () {
    test('daily 用 startDate、span 用 dueDate、todo 用 dueDate', () {
      final Task daily = _task(
        title: '打卡',
        type: TaskType.daily,
        startDate: DateTime(2026, 9, 10),
        dueDate: DateTime(2026, 9, 30),
      );
      final Task span = _task(
        title: '跨期',
        type: TaskType.span,
        startDate: DateTime(2026, 8, 1),
        dueDate: DateTime(2026, 9, 20),
      );
      final Task todo = _task(
        title: '待办',
        dueDate: DateTime(2026, 9, 5, 8, 0),
      );
      expect(dateSortKey(daily), DateTime(2026, 9, 10));
      expect(dateSortKey(span), DateTime(2026, 9, 20));
      expect(dateSortKey(todo), DateTime(2026, 9, 5));
    });

    test('daily 无 startDate 回退 dueDate', () {
      final Task daily = _task(
        title: '打卡',
        type: TaskType.daily,
        dueDate: DateTime(2026, 9, 3),
      );
      expect(dateSortKey(daily), DateTime(2026, 9, 3));
    });
  });
}

Task _task({
  required String title,
  required DateTime dueDate,
  String? dueTime,
  TaskType type = TaskType.todo,
  DateTime? startDate,
  Priority priority = Priority.normal,
  int? remindOffsetMin,
  bool completed = false,
}) {
  return Task(
    title: title,
    type: type,
    dueDate: dueDate,
    dueTime: dueTime,
    startDate: startDate,
    priority: priority,
    remindOffsetMin: remindOffsetMin,
    completed: completed,
  );
}
