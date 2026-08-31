import '../../data/models/course.dart';
import '../../data/models/holiday.dart';

/// 周次规则引擎（纯逻辑，可单测）。
///
/// 学期模型（对齐 PRD-课表模块 §3 与数据层 `Semester`）：开学日期
/// （`semesterStart`）即第 1 周的起始日——即便当日实际不是周一，也把它
/// 作为第 1 周的第 1 天。第 N 周覆盖日期区间：
/// `[semesterStart + (N-1)*7, semesterStart + (N-1)*7 + 6]`。
///
/// 提供三组判定：
/// - [weekOfDate]：日期 → 第几周；
/// - [WeekRules.hasClass]：某周该课程是否有课（每周/单周/双周/自定义）；
/// - [isCourseHoliday] / [WeekRules.isHoliday]：停课优先判定。
class WeekRules {
  WeekRules({required DateTime semesterStart, required this.totalWeeks})
      : _semesterStart = _dateOnly(semesterStart);

  /// 学期开学日期（第 1 周起始，仅年月日）。
  final DateTime _semesterStart;

  /// 学期总周数。
  final int totalWeeks;

  /// 第 [week] 周、星期 [weekday]（1=周一 … 7=周日）对应的日期（仅年月日）。
  ///
  /// 与停课判定、提醒计划共用同一套推算，保证「日期 ↔ 周次」互逆。
  DateTime weekDate(int weekday, int week) {
    final int offset = (weekday - _semesterStart.weekday + 7) % 7;
    return _dateOnly(
        _semesterStart.add(Duration(days: (week - 1) * 7 + offset)));
  }

  /// 由日期推算所属周次（1 起）。
  ///
  /// 开学日之前（含开学前同一 7 天段）归入第 1 周；超过学期总周数不封顶，
  /// 由调用方按需 `clamp(1, totalWeeks)`（如「回到本周」按钮）。
  int weekOfDate(DateTime date) {
    final int diff = _dayDiff(_semesterStart, date);
    if (diff < 0) return 1;
    return diff ~/ 7 + 1;
  }

  /// [course] 在第 [week] 周是否有课。
  ///
  /// 判定逻辑（PRD-课表模块 §3）：先受开始周~结束周限制，再按周次类型
  /// 过滤（每周始终有课 / 单周为奇 / 双周为偶 / 自定义看周序列）。
  static bool hasClass(Course course, int week) {
    if (week < course.startWeek || week > course.endWeek) return false;
    switch (course.weekType) {
      case WeekType.every:
        return true;
      case WeekType.odd:
        return week.isOdd;
      case WeekType.even:
        return week.isEven;
      case WeekType.custom:
        return course.weekList.contains(week);
    }
  }

  /// [course] 在第 [week] 周是否停课。
  ///
  /// 停课优先：命中 [holidays] 中全局（`courseId == null`）或针对该课程
  /// （`courseId == course.id`）的记录即停课，视图不展示、提醒不调度。
  bool isCourseHoliday(Course course, int week,
      {List<Holiday> holidays = const []}) {
    final DateTime date = weekDate(course.weekday, week);
    return isHoliday(date, course.id, holidays);
  }

  /// [date] 当天是否停课。[courseId] 为 null 时仅匹配全局停课。
  static bool isHoliday(DateTime date, int? courseId, List<Holiday> holidays) {
    for (final Holiday h in holidays) {
      if (h.date == date && (h.courseId == null || h.courseId == courseId)) {
        return true;
      }
    }
    return false;
  }

  /// 第 [week] 周是否存在全局停课（`courseId == null`），供视图提示用。
  bool hasGlobalHoliday(int week, {List<Holiday> holidays = const []}) {
    for (final Holiday h in holidays) {
      if (h.courseId != null) continue;
      if (weekOfDate(h.date) == week) return true;
    }
    return false;
  }

  /// 把周次收敛到 [1, totalWeeks]，供「回到本周」「显示周次」使用。
  int clampWeek(int week) => week.clamp(1, totalWeeks);

  static DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  /// 天数差（用 UTC 对齐避免夏令时/时区干扰）。
  static int _dayDiff(DateTime from, DateTime to) =>
      DateTime.utc(to.year, to.month, to.day)
          .difference(DateTime.utc(from.year, from.month, from.day))
          .inDays;
}
