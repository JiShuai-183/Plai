import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/holiday.dart';
import 'package:plai/data/models/period.dart';
import 'package:plai/data/models/semester.dart';
import 'package:plai/services/notifications/class_reminder_planner.dart';

void main() {
  // 2026-09-01 是周二（周二开学）。
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

  group('ClassReminderPlanner.expand', () {
    test('每周课程：按周范围展开，日期/时刻正确', () {
      const course = Course(
        id: 1,
        semesterId: 1,
        name: '高数',
        weekday: 3, // 周三
        startPeriod: 1,
        endPeriod: 2,
        weekType: WeekType.every,
        startWeek: 1,
        endWeek: 3,
      );

      final plans = ClassReminderPlanner.expand(
        course: course,
        semester: semester,
        periods: periods,
        holidays: const [],
        advanceMin: 10,
      );

      expect(plans, hasLength(3));
      expect(plans[0].week, 1);
      expect(plans[0].date, DateTime(2026, 9, 2)); // 第 1 周周三
      expect(plans[0].startTime, const TimeOfDay(hour: 8, minute: 0));
      expect(plans[1].date, DateTime(2026, 9, 9));
      expect(plans[2].date, DateTime(2026, 9, 16));
      expect(plans[0].advanceMin, 10);
    });

    test('单周课程：只保留奇数周', () {
      const course = Course(
        id: 2,
        semesterId: 1,
        name: '英语',
        weekday: 1, // 周一
        startPeriod: 2,
        endPeriod: 2,
        weekType: WeekType.odd,
        startWeek: 1,
        endWeek: 4,
      );

      final plans = ClassReminderPlanner.expand(
        course: course,
        semester: semester,
        periods: periods,
        holidays: const [],
        advanceMin: 0,
      );

      expect(plans.map((p) => p.week), [1, 3]);
      expect(plans[0].date, DateTime(2026, 9, 7)); // 第 1 周周一
      expect(plans[1].date, DateTime(2026, 9, 21)); // 第 3 周周一
      expect(plans[0].startTime, const TimeOfDay(hour: 8, minute: 55));
    });

    test('自定义周课程：只保留 weekList 中的周', () {
      const course = Course(
        id: 3,
        semesterId: 1,
        name: '体育',
        weekday: 5, // 周五
        startPeriod: 1,
        endPeriod: 1,
        weekType: WeekType.custom,
        weekList: [1, 4],
        startWeek: 1,
        endWeek: 5,
      );

      final plans = ClassReminderPlanner.expand(
        course: course,
        semester: semester,
        periods: periods,
        holidays: const [],
        advanceMin: 0,
      );

      expect(plans.map((p) => p.week), [1, 4]);
      expect(plans[0].date, DateTime(2026, 9, 4)); // 第 1 周周五
      expect(plans[1].date, DateTime(2026, 9, 25)); // 第 4 周周五
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
      // 第 1 周周三全局停课 + 第 2 周周三仅停高数。
      final holidays = [
        Holiday(date: DateTime(2026, 9, 2), courseId: null, reason: '全校活动'),
        Holiday(date: DateTime(2026, 9, 9), courseId: 1, reason: '调课'),
        Holiday(date: DateTime(2026, 9, 16), courseId: 99, reason: '他课停课'),
      ];

      final plans = ClassReminderPlanner.expand(
        course: course,
        semester: semester,
        periods: periods,
        holidays: holidays,
        advanceMin: 0,
      );

      // 第 1、2 周被跳过；第 3 周（停的是别的课）保留。
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

      final plans = ClassReminderPlanner.expand(
        course: course,
        semester: semester,
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

      final plans = ClassReminderPlanner.expand(
        course: course,
        semester: semester,
        periods: periods,
        holidays: const [],
        advanceMin: 0,
        from: DateTime(2026, 9, 10), // 第 1、2 周已过期
      );

      expect(plans.map((p) => p.week), [3]);
    });
  });
}
