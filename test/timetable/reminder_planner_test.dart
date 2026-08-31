import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/holiday.dart';
import 'package:plai/data/models/period.dart';
import 'package:plai/data/models/semester.dart';
import 'package:plai/features/timetable/reminder_planner.dart';
import 'package:plai/features/timetable/week_rules.dart';

void main() {
  // 2026-09-01 是周二（周二开学），第 N 周周三 = 开学日 + (N-1)*7 + 1 天。
  final semester = Semester(
    id: 1,
    name: '2026 秋',
    startDate: DateTime(2026, 9, 1),
    totalWeeks: 16,
  );

  const periods = [
    Period(index: 1, startTime: '08:00', endTime: '08:45'),
    Period(index: 2, startTime: '08:55', endTime: '09:40'),
    Period(index: 3, startTime: '10:00', endTime: '10:45'),
  ];

  group('buildClassReminderPlans（课表模块周次引擎展开）', () {
    test('每周课程：按周范围展开，日期/时刻正确', () {
      const course = Course(
        id: 1,
        semesterId: 1,
        name: '高数',
        weekday: 3,
        startPeriod: 1,
        endPeriod: 2,
        weekType: WeekType.every,
        startWeek: 1,
        endWeek: 3,
      );

      final plans = buildClassReminderPlans(
        semester: semester,
        courses: const [course],
        periods: periods,
        holidays: const [],
        advanceMin: 10,
      );

      expect(plans, hasLength(3));
      expect(plans.map((p) => p.week), [1, 2, 3]);
      expect(plans[0].date, DateTime(2026, 9, 2)); // 第 1 周周三
      expect(plans[0].startTime, const TimeOfDay(hour: 8, minute: 0));
      expect(plans[1].date, DateTime(2026, 9, 9));
      expect(plans[2].date, DateTime(2026, 9, 16));
      expect(plans[0].advanceMin, 10);
    });

    test('结束周超出学期总周数：只排到学期结束周（防导入脏数据）', () {
      const course = Course(
        id: 1,
        semesterId: 1,
        name: '高数',
        weekday: 3,
        startPeriod: 1,
        endPeriod: 2,
        weekType: WeekType.every,
        startWeek: 1,
        endWeek: 20, // 超出 semester.totalWeeks = 16
      );

      final plans = buildClassReminderPlans(
        semester: semester,
        courses: const [course],
        periods: periods,
        holidays: const [],
        advanceMin: 0,
      );

      // 最多排到第 16 周，且周次互逆推算的日期正确。
      expect(plans, hasLength(16));
      expect(plans.last.week, semester.totalWeeks);
      expect(plans.map((p) => p.week), everyElement(lessThanOrEqualTo(16)));
      expect(plans.last.date, DateTime(2026, 12, 16)); // 第 16 周周三
      final WeekRules rules = WeekRules(
        semesterStart: semester.startDate,
        totalWeeks: semester.totalWeeks,
      );
      expect(plans.last.date, rules.weekDate(3, 16));
    });

    test('开始周超出学期总周数：不产出计划', () {
      const course = Course(
        id: 2,
        semesterId: 1,
        name: '越界课',
        weekday: 3,
        startPeriod: 1,
        endPeriod: 1,
        weekType: WeekType.every,
        startWeek: 20,
        endWeek: 25,
      );

      final plans = buildClassReminderPlans(
        semester: semester,
        courses: const [course],
        periods: periods,
        holidays: const [],
        advanceMin: 0,
      );

      expect(plans, isEmpty);
    });

    test('单周课程：只保留奇数周', () {
      const course = Course(
        id: 3,
        semesterId: 1,
        name: '英语',
        weekday: 1,
        startPeriod: 2,
        endPeriod: 2,
        weekType: WeekType.odd,
        startWeek: 1,
        endWeek: 4,
      );

      final plans = buildClassReminderPlans(
        semester: semester,
        courses: const [course],
        periods: periods,
        holidays: const [],
        advanceMin: 0,
      );

      expect(plans.map((p) => p.week), [1, 3]);
      expect(plans[0].date, DateTime(2026, 9, 7)); // 第 1 周周一
      expect(plans[0].startTime, const TimeOfDay(hour: 8, minute: 55));
    });

    test('停课：全局停课或指定该课程停课会被跳过', () {
      const course = Course(
        id: 1,
        semesterId: 1,
        name: '高数',
        weekday: 3,
        startPeriod: 1,
        endPeriod: 2,
        weekType: WeekType.every,
        startWeek: 1,
        endWeek: 3,
      );
      // 第 1 周周三全局停课 + 第 2 周周三仅停高数 + 第 3 周停的是别的课。
      final holidays = [
        Holiday(date: DateTime(2026, 9, 2), courseId: null, reason: '全校活动'),
        Holiday(date: DateTime(2026, 9, 9), courseId: 1, reason: '调课'),
        Holiday(date: DateTime(2026, 9, 16), courseId: 99, reason: '他课停课'),
      ];

      final plans = buildClassReminderPlans(
        semester: semester,
        courses: const [course],
        periods: periods,
        holidays: holidays,
        advanceMin: 0,
      );

      expect(plans.map((p) => p.week), [3]);
    });

    test('节次缺失：无法确定上课时刻则跳过该课程', () {
      const course = Course(
        id: 9,
        semesterId: 1,
        name: '实验课',
        weekday: 3,
        startPeriod: 5, // 节次表里没有第 5 节
        endPeriod: 6,
        weekType: WeekType.every,
        startWeek: 1,
        endWeek: 2,
      );

      final plans = buildClassReminderPlans(
        semester: semester,
        courses: const [course],
        periods: periods,
        holidays: const [],
        advanceMin: 0,
      );

      expect(plans, isEmpty);
    });

    test('已过期：from 之后才产出计划', () {
      const course = Course(
        id: 1,
        semesterId: 1,
        name: '高数',
        weekday: 3,
        startPeriod: 1,
        endPeriod: 2,
        weekType: WeekType.every,
        startWeek: 1,
        endWeek: 3,
      );

      final plans = buildClassReminderPlans(
        semester: semester,
        courses: const [course],
        periods: periods,
        holidays: const [],
        advanceMin: 0,
        from: DateTime(2026, 9, 10), // 第 1、2 周已过期
      );

      expect(plans.map((p) => p.week), [3]);
    });
  });
}
