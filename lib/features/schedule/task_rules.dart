import '../../data/models/task.dart';

/// 优先级排序权重：紧急（0）→ 重要（1）→ 普通（2）。
int priorityOrder(Priority priority) {
  switch (priority) {
    case Priority.urgent:
      return 0;
    case Priority.important:
      return 1;
    case Priority.normal:
      return 2;
  }
}

/// 任务列表排序：逾期未完成置顶 → 优先级 → 截止日期 → 时刻。
///
/// 供今日视图与任务列表页统一使用。
int compareTasks(Task a, Task b, {DateTime? now}) {
  final DateTime current = now ?? DateTime.now();
  final bool aOverdue = isTaskOverdue(a, now: current);
  final bool bOverdue = isTaskOverdue(b, now: current);
  if (aOverdue != bOverdue) return aOverdue ? -1 : 1;
  final int priority =
      priorityOrder(a.priority).compareTo(priorityOrder(b.priority));
  if (priority != 0) return priority;
  final int date = a.dueDate.compareTo(b.dueDate);
  if (date != 0) return date;
  return (a.dueTime ?? '').compareTo(b.dueTime ?? '');
}

/// 是否逾期：未完成且已过截止时刻。
///
/// - 有具体时刻：now 晚于 `dueDate + dueTime`；
/// - 仅日期：当天 23:59:59 结束，次日 0 点起算逾期。
bool isTaskOverdue(Task task, {DateTime? now}) {
  if (task.completed) return false;
  final DateTime current = now ?? DateTime.now();
  return current.isAfter(taskDeadline(task));
}

/// 任务截止时刻。
///
/// - 有具体时刻：`dueDate + dueTime`（到点即逾期）；
/// - 仅日期：当天 23:59:59 结束（次日 0 点起算逾期）。
DateTime taskDeadline(Task task) {
  final String? time = task.dueTime;
  if (time != null && time.isNotEmpty) {
    final List<String> parts = time.split(':');
    if (parts.length == 2) {
      final int? hour = int.tryParse(parts[0]);
      final int? minute = int.tryParse(parts[1]);
      if (hour != null && minute != null) {
        return DateTime(task.dueDate.year, task.dueDate.month, task.dueDate.day,
            hour, minute, 0);
      }
    }
  }
  return DateTime(task.dueDate.year, task.dueDate.month, task.dueDate.day,
      23, 59, 59);
}

/// 计算任务提醒触发时刻（保存时写入 [Task.remindDate] 冗余存储）。
///
/// 规则与提醒调度器一致（《提醒调度接口.md》§4.2）：
/// - `remindOffsetMin == null` → 不提醒，返回 null；
/// - 否则触发时刻 = 截止时刻 - offset 分钟（`-1` 表示准时，offset 视作 0）。
DateTime? computeRemindAt(Task task) {
  final int? offsetMin = task.remindOffsetMin;
  if (offsetMin == null) return null;
  final DateTime? base = combineDueTime(task.dueDate, task.dueTime);
  if (base == null) return null;
  final int offset = offsetMin < 0 ? 0 : offsetMin;
  return base.subtract(Duration(minutes: offset));
}

/// 合并日期与 `HH:mm` 时刻为本地 [DateTime]。
///
/// 时刻缺失视为当天 00:00；格式非法返回 null。
DateTime? combineDueTime(DateTime date, String? time) {
  if (time == null) return DateTime(date.year, date.month, date.day);
  final List<String> parts = time.split(':');
  if (parts.length != 2) return null;
  final int? h = int.tryParse(parts[0]);
  final int? m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  return DateTime(date.year, date.month, date.day, h, m);
}
