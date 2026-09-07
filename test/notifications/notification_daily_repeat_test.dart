import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/services/notifications/notification_scheduler.dart';

/// 每日打卡重复提醒「首次触发时刻」纯逻辑测试（不触通知插件）。
void main() {
  Task daily({
    required DateTime start,
    required DateTime due,
    String? time,
  }) =>
      Task(
        title: '每日打卡',
        type: TaskType.daily,
        startDate: start,
        dueDate: due,
        dailyRemindTime: time,
      );

  group('dailyRepeatFirstAt', () {
    test('区间内今天时刻未过 → 今天该时刻首触发', () {
      final task = daily(
        start: DateTime(2026, 9, 1),
        due: DateTime(2026, 9, 30),
        time: '21:30',
      );
      final at = NotificationScheduler.dailyRepeatFirstAt(
        task,
        '21:30',
        now: DateTime(2026, 9, 7, 10, 0),
      );
      expect(at, DateTime(2026, 9, 7, 21, 30));
    });

    test('区间内今天时刻已过 → 明天该时刻首触发', () {
      final task = daily(
        start: DateTime(2026, 9, 1),
        due: DateTime(2026, 9, 30),
        time: '21:30',
      );
      final at = NotificationScheduler.dailyRepeatFirstAt(
        task,
        '21:30',
        now: DateTime(2026, 9, 7, 22, 0),
      );
      expect(at, DateTime(2026, 9, 8, 21, 30));
    });

    test('已过截止日 → null（不再调度）', () {
      final task = daily(
        start: DateTime(2026, 9, 1),
        due: DateTime(2026, 9, 30),
        time: '21:30',
      );
      final at = NotificationScheduler.dailyRepeatFirstAt(
        task,
        '21:30',
        now: DateTime(2026, 10, 2, 8, 0),
      );
      expect(at, isNull);
    });

    test('尚未到区间起点 → 从起点当天该时刻首触发', () {
      final task = daily(
        start: DateTime(2026, 9, 1),
        due: DateTime(2026, 9, 30),
        time: '21:30',
      );
      final at = NotificationScheduler.dailyRepeatFirstAt(
        task,
        '21:30',
        now: DateTime(2026, 8, 20, 10, 0),
      );
      expect(at, DateTime(2026, 9, 1, 21, 30));
    });

    test('截止日当天且时刻已过 → null（区间内无下一天可排）', () {
      final task = daily(
        start: DateTime(2026, 9, 1),
        due: DateTime(2026, 9, 7),
        time: '21:30',
      );
      final at = NotificationScheduler.dailyRepeatFirstAt(
        task,
        '21:30',
        now: DateTime(2026, 9, 7, 22, 0),
      );
      expect(at, isNull);
    });

    test('单日区间（start==due）今天时刻未过 → 今天首触发', () {
      final task = daily(
        start: DateTime(2026, 9, 7),
        due: DateTime(2026, 9, 7),
        time: '21:30',
      );
      final at = NotificationScheduler.dailyRepeatFirstAt(
        task,
        '21:30',
        now: DateTime(2026, 9, 7, 10, 0),
      );
      expect(at, DateTime(2026, 9, 7, 21, 30));
    });

    test('时刻缺失 / 非法 → null', () {
      final task = daily(
        start: DateTime(2026, 9, 1),
        due: DateTime(2026, 9, 30),
      );
      expect(
        NotificationScheduler.dailyRepeatFirstAt(
          task,
          null,
          now: DateTime(2026, 9, 7, 10, 0),
        ),
        isNull,
      );
      expect(
        NotificationScheduler.dailyRepeatFirstAt(
          task,
          '25:00',
          now: DateTime(2026, 9, 7, 10, 0),
        ),
        isNull,
      );
    });

    test('非 daily 类型即使带时刻 → null', () {
      final todo = Task(
        title: '待办',
        type: TaskType.todo,
        dueDate: DateTime(2026, 9, 30),
      );
      expect(
        NotificationScheduler.dailyRepeatFirstAt(
          todo,
          '21:30',
          now: DateTime(2026, 9, 7, 10, 0),
        ),
        isNull,
      );
    });

    test('非法区间（start > due）→ null', () {
      final task = daily(
        start: DateTime(2026, 9, 30),
        due: DateTime(2026, 9, 1),
        time: '21:30',
      );
      expect(
        NotificationScheduler.dailyRepeatFirstAt(
          task,
          '21:30',
          now: DateTime(2026, 9, 7, 10, 0),
        ),
        isNull,
      );
    });
  });
}
