import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/services/notifications/notification_scheduler.dart';

/// 每日提醒「首次触发时刻」纯逻辑测试（不触通知插件）。
///
/// 语义：所有任务类型共用 dailyRemindTime 做每日重复提醒。
/// - daily / span（区间型）：在 [start, due] 区间内每天；
/// - todo / scheduled：从今天起每天（无截止，勾完成即停由调度 completed 分支管）。
void main() {
  Task taskOf(TaskType type,
          {DateTime? start, DateTime? due, String? time}) =>
      Task(
        title: '提醒测试',
        type: type,
        startDate: start,
        dueDate: due ?? DateTime(2026, 9, 30),
        dailyRemindTime: time,
      );

  group('区间型 daily/span', () {
    test('区间内今天时刻未过 → 今天该时刻首触发', () {
      for (final TaskType type in [TaskType.daily, TaskType.span]) {
        final task = taskOf(
          type,
          start: DateTime(2026, 9, 1),
          due: DateTime(2026, 9, 30),
          time: '21:30',
        );
        final at = NotificationScheduler.dailyRemindFirstAt(
          task,
          '21:30',
          now: DateTime(2026, 9, 7, 10, 0),
        );
        expect(at, DateTime(2026, 9, 7, 21, 30), reason: 'type=$type');
      }
    });

    test('区间内今天时刻已过 → 明天该时刻首触发', () {
      for (final TaskType type in [TaskType.daily, TaskType.span]) {
        final task = taskOf(
          type,
          start: DateTime(2026, 9, 1),
          due: DateTime(2026, 9, 30),
          time: '21:30',
        );
        final at = NotificationScheduler.dailyRemindFirstAt(
          task,
          '21:30',
          now: DateTime(2026, 9, 7, 22, 0),
        );
        expect(at, DateTime(2026, 9, 8, 21, 30), reason: 'type=$type');
      }
    });

    test('已过截止日 → null（不再调度）', () {
      final task = taskOf(
        TaskType.daily,
        start: DateTime(2026, 9, 1),
        due: DateTime(2026, 9, 30),
        time: '21:30',
      );
      final at = NotificationScheduler.dailyRemindFirstAt(
        task,
        '21:30',
        now: DateTime(2026, 10, 2, 8, 0),
      );
      expect(at, isNull);
    });

    test('尚未到区间起点 → 从起点当天该时刻首触发', () {
      final task = taskOf(
        TaskType.span,
        start: DateTime(2026, 9, 1),
        due: DateTime(2026, 9, 30),
        time: '21:30',
      );
      final at = NotificationScheduler.dailyRemindFirstAt(
        task,
        '21:30',
        now: DateTime(2026, 8, 20, 10, 0),
      );
      expect(at, DateTime(2026, 9, 1, 21, 30));
    });

    test('截止日当天且时刻已过 → null（区间内无下一天可排）', () {
      final task = taskOf(
        TaskType.daily,
        start: DateTime(2026, 9, 1),
        due: DateTime(2026, 9, 7),
        time: '21:30',
      );
      final at = NotificationScheduler.dailyRemindFirstAt(
        task,
        '21:30',
        now: DateTime(2026, 9, 7, 22, 0),
      );
      expect(at, isNull);
    });

    test('单日区间（start==due）今天时刻未过 → 今天首触发', () {
      final task = taskOf(
        TaskType.daily,
        start: DateTime(2026, 9, 7),
        due: DateTime(2026, 9, 7),
        time: '21:30',
      );
      final at = NotificationScheduler.dailyRemindFirstAt(
        task,
        '21:30',
        now: DateTime(2026, 9, 7, 10, 0),
      );
      expect(at, DateTime(2026, 9, 7, 21, 30));
    });

    test('非法区间（start > due）→ null', () {
      final task = taskOf(
        TaskType.span,
        start: DateTime(2026, 9, 30),
        due: DateTime(2026, 9, 1),
        time: '21:30',
      );
      expect(
        NotificationScheduler.dailyRemindFirstAt(
          task,
          '21:30',
          now: DateTime(2026, 9, 7, 10, 0),
        ),
        isNull,
      );
    });
  });

  group('todo/scheduled（无截止，勾完成即停）', () {
    test('今天时刻未过 → 今天该时刻首触发', () {
      for (final TaskType type in [TaskType.todo, TaskType.scheduled]) {
        final task = taskOf(type, due: DateTime(2026, 9, 30), time: '21:30');
        final at = NotificationScheduler.dailyRemindFirstAt(
          task,
          '21:30',
          now: DateTime(2026, 9, 7, 10, 0),
        );
        expect(at, DateTime(2026, 9, 7, 21, 30), reason: 'type=$type');
      }
    });

    test('今天时刻已过 → 明天该时刻首触发', () {
      for (final TaskType type in [TaskType.todo, TaskType.scheduled]) {
        final task = taskOf(type, due: DateTime(2026, 9, 30), time: '21:30');
        final at = NotificationScheduler.dailyRemindFirstAt(
          task,
          '21:30',
          now: DateTime(2026, 9, 7, 22, 0),
        );
        expect(at, DateTime(2026, 9, 8, 21, 30), reason: 'type=$type');
      }
    });

    test('截止日已过仍从今天起排（无截止日语义）', () {
      final task = taskOf(
        TaskType.todo,
        due: DateTime(2026, 1, 1), // 早已过期
        time: '21:30',
      );
      final at = NotificationScheduler.dailyRemindFirstAt(
        task,
        '21:30',
        now: DateTime(2026, 9, 7, 10, 0),
      );
      expect(at, DateTime(2026, 9, 7, 21, 30));
    });
  });

  group('时刻缺失 / 非法', () {
    test('时刻缺失或非法 → null（各类型）', () {
      for (final TaskType type in TaskType.values) {
        final task = taskOf(type, time: null);
        expect(
          NotificationScheduler.dailyRemindFirstAt(
            task,
            null,
            now: DateTime(2026, 9, 7, 10, 0),
          ),
          isNull,
          reason: 'type=$type',
        );
        expect(
          NotificationScheduler.dailyRemindFirstAt(
            task,
            '25:00',
            now: DateTime(2026, 9, 7, 10, 0),
          ),
          isNull,
          reason: 'type=$type',
        );
      }
    });
  });
}
