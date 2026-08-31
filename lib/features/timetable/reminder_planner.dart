import 'package:flutter/material.dart';

import '../../data/models/course.dart';
import '../../data/models/holiday.dart';
import '../../data/models/period.dart';
import '../../data/models/semester.dart';
import '../../services/notifications/class_reminder_planner.dart';
import 'week_rules.dart';

/// 用课表模块的周次引擎把课程展开成「具体到某周某天某时刻」的提醒计划。
///
/// 与 plai-notify 的 [ClassReminderPlanner.expand] 等价，但以本模块的
/// [WeekRules] 为准（周次/停课规则统一，符合《提醒调度接口.md》：
/// 「由课表模块自己算好哪几周有课、跳过停课周，逐次调用」）。结果可传给
/// `NotificationScheduler.rescheduleAll(classPlans: ...)` 跳过内部展开。
List<ClassReminderPlan> buildClassReminderPlans({
  required Semester semester,
  required List<Course> courses,
  required List<Period> periods,
  required List<Holiday> holidays,
  required int advanceMin,
  DateTime? from,
}) {
  final WeekRules rules =
      WeekRules(semesterStart: semester.startDate, totalWeeks: semester.totalWeeks);
  final List<ClassReminderPlan> plans = <ClassReminderPlan>[];

  for (final Course course in courses) {
    final TimeOfDay? startTime = periodStartTime(course.startPeriod, periods);
    if (startTime == null) continue; // 节次表缺起始节次，无法确定上课时刻。
    for (int week = course.startWeek; week <= course.endWeek; week++) {
      if (!WeekRules.hasClass(course, week)) continue;
      final DateTime date = rules.weekDate(course.weekday, week);
      if (from != null && date.isBefore(from)) continue;
      if (rules.isCourseHoliday(course, week, holidays: holidays)) continue;
      plans.add(ClassReminderPlan(
        course: course,
        week: week,
        date: date,
        startTime: startTime,
        advanceMin: advanceMin,
      ));
    }
  }
  return plans;
}

/// 取指定节次序号的开始时刻；节次表缺失该序号时返回 null。
TimeOfDay? periodStartTime(int index, List<Period> periods) {
  for (final Period p in periods) {
    if (p.index == index) {
      final List<String> parts = p.startTime.split(':');
      if (parts.length != 2) return null;
      final int? h = int.tryParse(parts[0]);
      final int? m = int.tryParse(parts[1]);
      if (h == null || m == null) return null;
      return TimeOfDay(hour: h, minute: m);
    }
  }
  return null;
}
