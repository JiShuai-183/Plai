import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/holiday.dart';
import 'package:plai/features/timetable/week_rules.dart';

void main() {
  group('WeekRules.weekOfDate', () {
    test('周一开学：逐周推算', () {
      final rules = WeekRules(
        semesterStart: DateTime(2026, 9, 1),
        totalWeeks: 16,
      );
      expect(rules.weekOfDate(DateTime(2026, 9, 1)), 1); // 第1周起始日
      expect(rules.weekOfDate(DateTime(2026, 9, 7)), 1); // +6 仍为第1周
      expect(rules.weekOfDate(DateTime(2026, 9, 8)), 2); // +7 第2周
      expect(rules.weekOfDate(DateTime(2026, 9, 14)), 2);
      expect(rules.weekOfDate(DateTime(2026, 9, 21)), 3);
      // 第16周起始 = 9/1 + 105 天；+111 天仍在第16周内。
      expect(rules.weekOfDate(DateTime(2026, 9, 1).add(Duration(days: 105))), 16);
      expect(rules.weekOfDate(DateTime(2026, 9, 1).add(Duration(days: 111))), 16);
    });

    test('非周一开学：开学日所在 7 天段为第 1 周', () {
      final rules = WeekRules(
        semesterStart: DateTime(2026, 9, 3),
        totalWeeks: 16,
      );
      expect(rules.weekOfDate(DateTime(2026, 9, 3)), 1);
      expect(rules.weekOfDate(DateTime(2026, 9, 9)), 1); // +6
      expect(rules.weekOfDate(DateTime(2026, 9, 10)), 2); // +7
    });

    test('开学前归入第 1 周', () {
      final rules = WeekRules(
        semesterStart: DateTime(2026, 9, 1),
        totalWeeks: 16,
      );
      expect(rules.weekOfDate(DateTime(2026, 8, 30)), 1);
    });

    test('weekDate 与 weekOfDate 互逆', () {
      final rules = WeekRules(
        semesterStart: DateTime(2026, 9, 1),
        totalWeeks: 16,
      );
      for (int week = 1; week <= 16; week++) {
        for (int weekday = 1; weekday <= 7; weekday++) {
          final DateTime date = rules.weekDate(weekday, week);
          expect(rules.weekOfDate(date), week);
        }
      }
    });

    test('clampWeek 收敛到 [1, totalWeeks]', () {
      final rules = WeekRules(
        semesterStart: DateTime(2026, 9, 1),
        totalWeeks: 16,
      );
      expect(rules.clampWeek(0), 1);
      expect(rules.clampWeek(1), 1);
      expect(rules.clampWeek(17), 16);
      expect(rules.clampWeek(8), 8);
    });
  });

  group('WeekRules.hasClass', () {
    Course course({
      WeekType type = WeekType.every,
      List<int> list = const [],
      int start = 1,
      int end = 16,
    }) =>
        Course(
          semesterId: 1,
          name: '高数',
          weekType: type,
          weekList: list,
          startWeek: start,
          endWeek: end,
          weekday: 1,
          startPeriod: 1,
          endPeriod: 2,
        );

    test('每周：范围内均有课', () {
      expect(WeekRules.hasClass(course(), 1), isTrue);
      expect(WeekRules.hasClass(course(), 16), isTrue);
      expect(WeekRules.hasClass(course(), 17), isFalse); // 超出结束周
    });

    test('单周：奇数为有课', () {
      expect(WeekRules.hasClass(course(type: WeekType.odd), 1), isTrue);
      expect(WeekRules.hasClass(course(type: WeekType.odd), 3), isTrue);
      expect(WeekRules.hasClass(course(type: WeekType.odd), 2), isFalse);
    });

    test('双周：偶数为有课', () {
      expect(WeekRules.hasClass(course(type: WeekType.even), 2), isTrue);
      expect(WeekRules.hasClass(course(type: WeekType.even), 1), isFalse);
    });

    test('自定义周序列', () {
      final c = course(type: WeekType.custom, list: [1, 3, 5, 8]);
      expect(WeekRules.hasClass(c, 3), isTrue);
      expect(WeekRules.hasClass(c, 5), isTrue);
      expect(WeekRules.hasClass(c, 4), isFalse);
      expect(WeekRules.hasClass(c, 2), isFalse);
    });

    test('范围限制优先于单双周', () {
      final c = course(type: WeekType.odd, start: 3, end: 10);
      expect(WeekRules.hasClass(c, 1), isFalse); // 1 为奇但不在范围内
      expect(WeekRules.hasClass(c, 3), isTrue);
      expect(WeekRules.hasClass(c, 11), isFalse);
    });
  });

  group('WeekRules 停课优先', () {
    test('全局停课命中任意课程', () {
      final rules = WeekRules(
        semesterStart: DateTime(2026, 9, 1),
        totalWeeks: 16,
      );
      final course = Course(
        semesterId: 1,
        name: '高数',
        weekday: 3,
        startPeriod: 1,
        endPeriod: 2,
        endWeek: 16,
      );
      final holidayDate = rules.weekDate(3, 1); // 第1周周三上课日
      final holidays = [
        Holiday(date: holidayDate, courseId: null, reason: '国庆'),
      ];
      expect(rules.isCourseHoliday(course, 1, holidays: holidays), isTrue);
      expect(rules.isCourseHoliday(course, 2, holidays: holidays), isFalse);
    });

    test('课程级停课只命中该课程', () {
      final rules = WeekRules(
        semesterStart: DateTime(2026, 9, 1),
        totalWeeks: 16,
      );
      final a = Course(
        semesterId: 1,
        id: 1,
        name: '高数',
        weekday: 3,
        startPeriod: 1,
        endPeriod: 2,
      );
      final b = Course(
        semesterId: 1,
        id: 2,
        name: '英语',
        weekday: 3,
        startPeriod: 1,
        endPeriod: 2,
      );
      final holidayDate = rules.weekDate(3, 1);
      final holidays = [
        Holiday(date: holidayDate, courseId: 1, reason: '调停课'),
      ];
      expect(rules.isCourseHoliday(a, 1, holidays: holidays), isTrue);
      expect(rules.isCourseHoliday(b, 1, holidays: holidays), isFalse);
    });
  });
}
