import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/services/notifications/notification_scheduler.dart';

/// 「不重复」提醒「触发时刻」纯逻辑测试（不触通知插件）。
///
/// 语义：`reminderRepeat == once` 时只在 `remindOnceAt` 那一刻响一次，
/// 与任务截止日无关；解析规则见 `NotificationScheduler.onceRemindAt`。
void main() {
  Task taskOf({
    TaskType type = TaskType.todo,
    DateTime? due,
    DateTime? onceAt,
    String? dailyTime,
    bool completed = false,
  }) =>
      Task(
        id: 1,
        title: '一次性提醒测试',
        type: type,
        dueDate: due ?? DateTime(2026, 11, 30),
        dailyRemindTime: dailyTime,
        reminderRepeat: ReminderRepeat.once,
        remindOnceAt: onceAt,
        completed: completed,
      );

  group('onceRemindAt 基本语义', () {
    test('未来时刻原样返回（秒/毫秒归零到分钟）', () {
      final task = taskOf(onceAt: DateTime(2026, 11, 2, 9, 30, 45, 123));
      final at = NotificationScheduler.onceRemindAt(
        task,
        now: DateTime(2026, 11, 1, 20, 0),
      );
      expect(at, DateTime(2026, 11, 2, 9, 30));
    });

    test('缺失 remindOnceAt → null（不可调度）', () {
      final task = taskOf();
      expect(
        NotificationScheduler.onceRemindAt(task, now: DateTime(2026, 11, 1)),
        isNull,
      );
    });

    test('恰好等于 now → null（已过期，不补发）', () {
      final task = taskOf(onceAt: DateTime(2026, 11, 2, 9, 30));
      expect(
        NotificationScheduler.onceRemindAt(
            task, now: DateTime(2026, 11, 2, 9, 30)),
        isNull,
      );
    });

    test('过去时刻 → null（恢复旧备份不会立刻误响）', () {
      final task = taskOf(onceAt: DateTime(2026, 10, 1, 8, 0));
      expect(
        NotificationScheduler.onceRemindAt(
            task, now: DateTime(2026, 11, 2, 9, 0)),
        isNull,
      );
    });

    test('可排到未来一年内任意天（不受任务截止日约束）', () {
      // 截止日 11/30，但提醒排在 12/24（跨过截止日、跨月）。
      final task = taskOf(
        due: DateTime(2026, 11, 30),
        onceAt: DateTime(2026, 12, 24, 7, 5),
      );
      expect(
        NotificationScheduler.onceRemindAt(
            task, now: DateTime(2026, 11, 1, 0, 0)),
        DateTime(2026, 12, 24, 7, 5),
      );
    });
  });

  group('once 与每日重复互斥', () {
    test('once 任务即使带着 dailyRemindTime，也以 remindOnceAt 为准', () {
      // 调度入口先判 reminderRepeat == once，再做 dailyRemindTime 分支，
      // 所以两者的触发时刻必然是 remindOnceAt。
      final task = taskOf(
        dailyTime: '08:00',
        onceAt: DateTime(2026, 11, 5, 18, 45),
      );
      expect(task.reminderRepeat, ReminderRepeat.once);
      expect(
        NotificationScheduler.onceRemindAt(
            task, now: DateTime(2026, 11, 1, 0, 0)),
        DateTime(2026, 11, 5, 18, 45),
      );
      // 每日分支仍按自己的纯函数算（互不干扰，供回滚/老数据兜底）。
      expect(
        NotificationScheduler.dailyRemindFirstAt(task, '08:00',
            now: DateTime(2026, 11, 1, 0, 0)),
        DateTime(2026, 11, 1, 8, 0),
      );
    });

    test('reminderRepeat 为空的老任务不会被 onceRemindAt 命中', () {
      final legacy = Task(
        id: 2,
        title: '老任务',
        type: TaskType.todo,
        dueDate: DateTime(2026, 11, 30),
        dailyRemindTime: '07:00',
        remindOnceAt: DateTime(2026, 12, 1, 7, 0),
      );
      expect(legacy.reminderRepeat, isNull);
      // 字段存在但 repeat 未设置时，调度入口不会走 once 分支；
      // 纯函数本身只看 remindOnceAt，故由入口的分支顺序保证语义。
      expect(
        NotificationScheduler.dailyRemindFirstAt(legacy, '07:00',
            now: DateTime(2026, 11, 1, 0, 0)),
        DateTime(2026, 11, 1, 7, 0),
      );
    });
  });

  group('各任务类型都支持不重复提醒', () {
    test('daily / span / scheduled / todo 一律按 remindOnceAt 排', () {
      final DateTime at = DateTime(2026, 11, 4, 21, 15);
      for (final TaskType type in TaskType.values) {
        final task = taskOf(
          type: type,
          due: DateTime(2026, 11, 10),
          onceAt: at,
        );
        expect(
          NotificationScheduler.onceRemindAt(
              task, now: DateTime(2026, 11, 1, 0, 0)),
          at,
          reason: 'type=$type',
        );
      }
    });
  });
}
