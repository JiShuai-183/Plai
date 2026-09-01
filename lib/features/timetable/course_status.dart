import '../../data/models/course.dart';
import '../../data/models/period.dart';

/// 课程状态（仅对「当前周 + 今天」的课生效）。
enum CourseStatus {
  /// 还未上（当前时刻早于起始节次开始时间）。
  upcoming,

  /// 正在上（当前时刻落在起始节次开始 ~ 结束节次结束之间）。
  ongoing,

  /// 上完（当前时刻晚于结束节次结束时间）。
  finished,
}

/// 计算课程在 [now] 时刻的状态；非「当前周 + 今天」或节次缺失时返回 null。
///
/// 判定边界（纯分钟数比较，`HH:mm` → 距 0 点分钟数）：
/// - `nowMin < 起始节次 startTime` → [CourseStatus.upcoming]；
/// - `nowMin > 结束节次 endTime` → [CourseStatus.finished]；
/// - 其余（`startTime <= nowMin <= endTime`）→ [CourseStatus.ongoing]。
///
/// 跨多节次课程按首节 startTime、末节 endTime 判定；两门课紧邻（前一门
/// 结束 == 后一门开始）时按分钟数严格比较，不会同时判为 ongoing。
///
/// 前置条件（与 [isTodayWeek] 语义对齐）：
/// - [isTodayWeek] 为 false（当前查看周不是 now 所在周）→ null；
/// - [course.weekday] 与 [now.weekday] 不一致（Dart DateTime.weekday 与
///   Course.weekday 同为 1=周一 … 7=周日）→ null；
/// - 在 [periods] 中按 index 找不到起始/结束节次，或时间格式非法 → null。
CourseStatus? courseStatusOf({
  required Course course,
  required List<Period> periods,
  required DateTime now,
  required bool isTodayWeek,
}) {
  if (!isTodayWeek) return null;
  if (course.weekday != now.weekday) return null;

  final Period? start = _periodByIndex(periods, course.startPeriod);
  final Period? end = _periodByIndex(periods, course.endPeriod);
  if (start == null || end == null) return null;

  final int? startMin = _minutesOf(start.startTime);
  final int? endMin = _minutesOf(end.endTime);
  if (startMin == null || endMin == null) return null;

  final int nowMin = now.hour * 60 + now.minute;
  if (nowMin < startMin) return CourseStatus.upcoming;
  if (nowMin > endMin) return CourseStatus.finished;
  return CourseStatus.ongoing;
}

/// 今天可视课程中下一次状态跳变的时刻（精确到上课/下课整分）。
///
/// 课程状态只在「起始节次开始时刻」（upcoming→ongoing）与「结束节次结束
/// 时刻」（ongoing→finished）两个离散点跳变，用固定周期轮询会让下课/上课
/// 的显示最多滞后一个周期。这里返回 [now] 所在日、严格晚于 [now] 的最早
/// 边界（年月日 + 小时 + 分钟，秒/毫秒归零），供视图在跳变时刻精确刷新；
/// 今天已无未来边界、或课程/节次缺失时返回 null。
DateTime? nextStatusChangeBoundary({
  required List<Course> courses,
  required List<Period> periods,
  required DateTime now,
}) {
  DateTime? earliest;
  for (final Course c in courses) {
    final Period? start = _periodByIndex(periods, c.startPeriod);
    final Period? end = _periodByIndex(periods, c.endPeriod);
    final int? startMin = start == null ? null : _minutesOf(start.startTime);
    final int? endMin = end == null ? null : _minutesOf(end.endTime);
    for (final int? min in <int?>[startMin, endMin]) {
      if (min == null) continue;
      final DateTime boundary =
          DateTime(now.year, now.month, now.day, min ~/ 60, min % 60);
      if (boundary.isAfter(now) &&
          (earliest == null || boundary.isBefore(earliest))) {
        earliest = boundary;
      }
    }
  }
  return earliest;
}

/// 按节次序号查找节次，找不到返回 null。
Period? _periodByIndex(List<Period> periods, int index) {
  for (final Period p in periods) {
    if (p.index == index) return p;
  }
  return null;
}

/// 解析 `HH:mm` 为距 0 点分钟数；格式非法返回 null。
int? _minutesOf(String hhmm) {
  final List<String> parts = hhmm.split(':');
  if (parts.length != 2) return null;
  final int? hour = int.tryParse(parts[0]);
  final int? minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return null;
  return hour * 60 + minute;
}
