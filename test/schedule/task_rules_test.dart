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
}

Task _task({
  required String title,
  required DateTime dueDate,
  String? dueTime,
  Priority priority = Priority.normal,
  int? remindOffsetMin,
  bool completed = false,
}) {
  return Task(
    title: title,
    type: TaskType.todo,
    dueDate: dueDate,
    dueTime: dueTime,
    priority: priority,
    remindOffsetMin: remindOffsetMin,
    completed: completed,
  );
}
