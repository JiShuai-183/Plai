import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/period.dart';
import 'package:plai/features/timetable/course_status.dart';

void main() {
  // 第 1 节 08:00-08:50，第 2 节 09:00-09:50，第 3 节 10:00-10:50。
  const List<Period> periods = [
    Period(index: 1, startTime: '08:00', endTime: '08:50'),
    Period(index: 2, startTime: '09:00', endTime: '09:50'),
    Period(index: 3, startTime: '10:00', endTime: '10:50'),
  ];

  Course course({required int weekday, int start = 2, int end = 3}) => Course(
        semesterId: 1,
        name: '高数',
        weekday: weekday,
        startPeriod: start,
        endPeriod: end,
      );

  DateTime nowAt(int hour, int minute) =>
      DateTime(2026, 9, 1, hour, minute);

  test('upcoming：now 早于起始节次开始时间', () {
    final DateTime now = nowAt(7, 59);
    final Course c = course(weekday: now.weekday);
    expect(
      courseStatusOf(
        course: c,
        periods: periods,
        now: now,
        isTodayWeek: true,
      ),
      CourseStatus.upcoming,
    );
  });

  test('ongoing：now 落在起始节次开始 ~ 结束节次结束之间', () {
    final DateTime now = nowAt(9, 25);
    final Course c = course(weekday: now.weekday);
    expect(
      courseStatusOf(
        course: c,
        periods: periods,
        now: now,
        isTodayWeek: true,
      ),
      CourseStatus.ongoing,
    );
  });

  test('ongoing 边界：now 等于起始节次开始时刻', () {
    final DateTime now = nowAt(9, 0);
    final Course c = course(weekday: now.weekday);
    expect(
      courseStatusOf(
        course: c,
        periods: periods,
        now: now,
        isTodayWeek: true,
      ),
      CourseStatus.ongoing,
    );
  });

  test('ongoing 边界：now 等于结束节次结束时刻', () {
    final DateTime now = nowAt(10, 50);
    final Course c = course(weekday: now.weekday);
    expect(
      courseStatusOf(
        course: c,
        periods: periods,
        now: now,
        isTodayWeek: true,
      ),
      CourseStatus.ongoing,
    );
  });

  test('finished：now 晚于结束节次结束时间', () {
    final DateTime now = nowAt(10, 51);
    final Course c = course(weekday: now.weekday);
    expect(
      courseStatusOf(
        course: c,
        periods: periods,
        now: now,
        isTodayWeek: true,
      ),
      CourseStatus.finished,
    );
  });

  test('跨多节次课程按首末节判定', () {
    final Course c = course(weekday: nowAt(9, 25).weekday, start: 1, end: 3);
    // 第 1 节开始前：未上；第 2 节（中间节）：正在上；第 3 节结束：正在上。
    expect(
      courseStatusOf(
        course: c,
        periods: periods,
        now: nowAt(7, 59),
        isTodayWeek: true,
      ),
      CourseStatus.upcoming,
    );
    expect(
      courseStatusOf(
        course: c,
        periods: periods,
        now: nowAt(9, 25),
        isTodayWeek: true,
      ),
      CourseStatus.ongoing,
    );
    expect(
      courseStatusOf(
        course: c,
        periods: periods,
        now: nowAt(10, 50),
        isTodayWeek: true,
      ),
      CourseStatus.ongoing,
    );
  });

  test('非今天（星期不匹配）→ null', () {
    final DateTime now = nowAt(9, 25);
    final Course c = course(weekday: now.weekday % 7 + 1);
    expect(
      courseStatusOf(
        course: c,
        periods: periods,
        now: now,
        isTodayWeek: true,
      ),
      isNull,
    );
  });

  test('非当前周（isTodayWeek=false）→ null', () {
    final DateTime now = nowAt(9, 25);
    final Course c = course(weekday: now.weekday);
    expect(
      courseStatusOf(
        course: c,
        periods: periods,
        now: now,
        isTodayWeek: false,
      ),
      isNull,
    );
  });

  test('节次缺失（periods 找不到起始/结束节次）→ null', () {
    final DateTime now = nowAt(9, 25);
    final Course c = course(weekday: now.weekday, start: 5, end: 6);
    expect(
      courseStatusOf(
        course: c,
        periods: periods,
        now: now,
        isTodayWeek: true,
      ),
      isNull,
    );
  });

  test('节次时间格式非法 → null', () {
    final DateTime now = nowAt(9, 25);
    final Course c = course(weekday: now.weekday);
    const List<Period> badPeriods = [
      Period(index: 2, startTime: '09', endTime: '09:50'),
      Period(index: 3, startTime: '10:00', endTime: '10:50'),
    ];
    expect(
      courseStatusOf(
        course: c,
        periods: badPeriods,
        now: now,
        isTodayWeek: true,
      ),
      isNull,
    );
  });
}
