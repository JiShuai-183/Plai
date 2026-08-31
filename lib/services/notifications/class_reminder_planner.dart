import 'package:flutter/material.dart';

import '../../data/models/course.dart';
import '../../data/models/holiday.dart';
import '../../data/models/period.dart';
import '../../data/models/semester.dart';

/// 一次上课提醒的调度计划（具体到某周某天某时刻）。
///
/// 由「课程」展开而来，供 [NotificationScheduler.rescheduleAll] 全量重排使用，
/// 也允许课表模块把算好的实例列表直接传入，跳过内部展开。
class ClassReminderPlan {
  const ClassReminderPlan({
    required this.course,
    required this.week,
    required this.date,
    required this.startTime,
    this.advanceMin,
  });

  /// 对应的课程。
  final Course course;

  /// 第几周（用于深链定位课表周 + 通知 ID 稳定性）。
  final int week;

  /// 上课日期（仅年月日）。
  final DateTime date;

  /// 上课时刻（节次开始时间）。
  final TimeOfDay startTime;

  /// 提前提醒分钟数；null 时由调用方采用设置默认值。
  final int? advanceMin;
}

/// 课程 → 具体上课提醒计划的展开器（供全量重排兜底使用）。
///
/// 边界说明：本类只负责把「一门课展开成若干次具体上课提醒」，**不提供**
/// `weekOfDate` / `hasClass` 这类「日期→周次」判定 —— 那是课表模块
/// （plai-timetable）的职责。若 timetable 后续提供规范周次引擎，
/// 可在调用 [NotificationScheduler.rescheduleAll] 时直接传入现成的
/// [ClassReminderPlan] 列表；本类仅作为无外部依赖时的兜底实现。
abstract final class ClassReminderPlanner {
  /// 展开 [course] 在 [semester] 内的全部上课提醒计划。
  ///
  /// - 周次范围：`startWeek..endWeek`，按 `weekType` / `weekList` 过滤；
  /// - 日期：由学期开学日 + 周序 + 星期推算；
  /// - 停课：命中 `holidays`（全局 `courseId == null` 或对应该课程）跳过；
  /// - 已过期的提醒不产出（`from` 之后才调度，默认现在）。
  static List<ClassReminderPlan> expand({
    required Course course,
    required Semester semester,
    required List<Period> periods,
    required List<Holiday> holidays,
    required int advanceMin,
    DateTime? from,
  }) {
    final List<ClassReminderPlan> plans = [];
    final DateTime fromDate = _dateOnly(from ?? DateTime.now());

    final TimeOfDay? startTime = _periodStartTime(course.startPeriod, periods);
    if (startTime == null) {
      // 节次表缺少该课程的起始节次 → 无法确定上课时刻，跳过该课程。
      return plans;
    }

    for (int week = course.startWeek; week <= course.endWeek; week++) {
      if (!_weekMatches(course, week)) continue;
      final DateTime date =
          _weekDate(semester.startDate, course.weekday, week);
      if (date.isBefore(fromDate)) continue;
      if (_isHoliday(date, course.id, holidays)) continue;
      plans.add(ClassReminderPlan(
        course: course,
        week: week,
        date: date,
        startTime: startTime,
        advanceMin: advanceMin,
      ));
    }
    return plans;
  }

  /// 周次是否属于该课程（每周/单周/双周/自定义）。
  static bool _weekMatches(Course course, int week) {
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

  /// 第 [week] 周、[courseWeekday]（1=周一…7=周日）对应的日期。
  static DateTime _weekDate(DateTime semesterStart, int courseWeekday, int week) {
    final int offset = (courseWeekday - semesterStart.weekday + 7) % 7;
    return _dateOnly(
        semesterStart.add(Duration(days: (week - 1) * 7 + offset)));
  }

  /// 该日期是否停课（全局停课或仅该课程停课）。
  static bool _isHoliday(DateTime date, int? courseId, List<Holiday> holidays) {
    for (final Holiday h in holidays) {
      if (h.date != date) continue;
      if (h.courseId == null || h.courseId == courseId) return true;
    }
    return false;
  }

  /// 取指定节次序号的开始时刻；缺失返回 null。
  static TimeOfDay? _periodStartTime(int index, List<Period> periods) {
    for (final Period p in periods) {
      if (p.index == index) return _parseTime(p.startTime);
    }
    return null;
  }

  /// 解析 `HH:mm` → [TimeOfDay]。
  static TimeOfDay? _parseTime(String value) {
    final List<String> parts = value.split(':');
    if (parts.length != 2) return null;
    final int? h = int.tryParse(parts[0]);
    final int? m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h, minute: m);
  }

  /// 归一化为仅含年月日的本地日期。
  static DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);
}
