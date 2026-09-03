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

/// 任务列表排序：逾期未完成置顶 → 优先级 → 日期序键 → 时刻。
///
/// 供今日视图与任务列表页统一使用。
/// 日期序键按类型取（见 [dateSortKey]）：daily 用 startDate、span 用 dueDate。
/// 取舍：daily 无整体逾期不进"置顶"，按开始日聚拢，便于接入按天/列表视图；
/// span 逾期按 dueDate 判，排序键与其截止一致。均只作分组骨架，
/// 精确的按天视图筛选复用 [taskActiveOn]。
int compareTasks(Task a, Task b, {DateTime? now}) {
  final DateTime current = now ?? DateTime.now();
  final bool aOverdue = isTaskOverdue(a, now: current);
  final bool bOverdue = isTaskOverdue(b, now: current);
  if (aOverdue != bOverdue) return aOverdue ? -1 : 1;
  final int priority =
      priorityOrder(a.priority).compareTo(priorityOrder(b.priority));
  if (priority != 0) return priority;
  final int date = dateSortKey(a).compareTo(dateSortKey(b));
  if (date != 0) return date;
  return (a.dueTime ?? '').compareTo(b.dueTime ?? '');
}

/// 类型感知的日期排序键（仅自然日，丢弃时刻）。
///
/// - daily：startDate（缺失回退 dueDate）——按开始日聚拢；
/// - span / todo / scheduled：dueDate —— 对齐截止日。
DateTime dateSortKey(Task task) {
  final DateTime raw = task.type == TaskType.daily
      ? (task.startDate ?? task.dueDate)
      : task.dueDate;
  return _dateOnly(raw);
}

/// 是否逾期：未完成且已过截止时刻。
///
/// - 每日打卡(daily)恒返回 false：无"整体完成"，缺卡按天记录，不进逾期置顶；
/// - 其余类型有具体时刻：now 晚于 `dueDate + dueTime`；
/// - 仅日期：当天 23:59:59 结束，次日 0 点起算逾期。
/// - span 复用本函数：视为截止在 dueDate（可有/无 dueTime）。
bool isTaskOverdue(Task task, {DateTime? now}) {
  if (task.type == TaskType.daily) return false;
  if (task.completed) return false;
  final DateTime current = now ?? DateTime.now();
  return current.isAfter(taskDeadline(task));
}

/// 任务截止时刻。
///
/// - 有具体时刻：`dueDate + dueTime`（到点即逾期）；
/// - 仅日期：当天 23:59:59 结束（次日 0 点起算逾期）。
/// - daily/span 同规则取 dueDate 侧（daily 实际不被 isTaskOverdue 使用）。
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

/// 某天 [day] 是否落在任务"活跃区间"（自然日语义，day 可带任意时刻）。
///
/// - daily / span：`startDate <= day <= dueDate`（含端点）；startDate 缺失视同
///   单日（startDate = dueDate）；startDate > dueDate 非法区间恒不活跃。
/// - todo / scheduled：仅 `dueDate == day`。
///
/// 供按天视图 / 每日筛选后续复用。
bool taskActiveOn(Task task, DateTime day) {
  switch (task.type) {
    case TaskType.daily:
    case TaskType.span:
      return _inClosedRange(day, task.startDate ?? task.dueDate, task.dueDate);
    case TaskType.todo:
    case TaskType.scheduled:
      return _sameDay(_dateOnly(day), task.dueDate);
  }
}

/// daily：当天 [day] 是否开放打卡（有实例可出现）——`startDate <= day <= dueDate`。
///
/// 仅对 daily 有意义，其余类型返回 false。区间端点均含；区间非法（start > due）
/// 或不含 [day] 返回 false。
bool isDailyOpenOn(Task task, DateTime day) {
  if (task.type != TaskType.daily) return false;
  return taskActiveOn(task, day);
}

/// daily：当天 [day] 是否已有完成记录。
///
/// [doneDates] 由调用方从打卡日志（task_daily_logs）归一后传入，规则层不读库；
/// 集合元素可带时刻，成员判定按自然日归一（同一 y/m/d 即命中）。
bool isDailyDoneOn(Task task, DateTime day,
    {required Set<DateTime> doneDates}) {
  final DateTime d = _dateOnly(day);
  for (final DateTime done in doneDates) {
    if (_sameDay(_dateOnly(done), d)) return true;
  }
  return false;
}

/// 计算任务提醒触发时刻（保存时写入 [Task.remindDate] 冗余存储）。
///
/// 规则与提醒调度器一致（《提醒调度接口.md》§4.2）：
/// - daily / span 现阶段无提醒 UI，恒返回 null；
/// - `remindOffsetMin == null` → 不提醒，返回 null；
/// - 否则触发时刻 = 截止时刻 - offset 分钟（`-1` 表示准时，offset 视作 0）。
DateTime? computeRemindAt(Task task) {
  if (task.type == TaskType.daily || task.type == TaskType.span) return null;
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

/// 归一为自然日（丢弃时刻），供逐日语义比较。
DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// 是否同一自然日。
bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 闭区间 `start <= day <= end`（均按自然日比较；start > end 恒 false）。
bool _inClosedRange(DateTime day, DateTime start, DateTime end) {
  final DateTime d = _dateOnly(day);
  return !d.isBefore(_dateOnly(start)) && !d.isAfter(_dateOnly(end));
}
