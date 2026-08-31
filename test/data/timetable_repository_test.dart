import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/holiday.dart';
import 'package:plai/data/models/period.dart';
import 'package:plai/data/models/semester.dart';

import 'test_helpers.dart';

void main() {
  late TestData data;

  setUp(() async {
    data = await TestData.create();
  });

  tearDown(() async {
    await data.db.close();
  });

  // ---- Semester ----

  test('Semester CRUD 往返一致', () async {
    final repo = data.timetable;
    final semester = Semester(name: '2026 秋', startDate: DateTime(2026, 9, 1), totalWeeks: 16);
    final id = await repo.insertSemester(semester);

    final fetched = await repo.getSemesterById(id);
    expect(fetched, semester.copyWith(id: id));

    final updated = fetched!.copyWith(name: '2026 秋（上）', totalWeeks: 18);
    expect(await repo.updateSemester(updated), 1);
    expect((await repo.getSemesterById(id))!.totalWeeks, 18);

    expect(await repo.deleteSemester(id), 1);
    expect(await repo.getSemesterById(id), isNull);
  });

  test('getSemesters 按开学日期倒序', () async {
    final repo = data.timetable;
    await repo.insertSemester(Semester(name: '旧', startDate: DateTime(2025, 9, 1), totalWeeks: 16));
    await repo.insertSemester(Semester(name: '新', startDate: DateTime(2026, 9, 1), totalWeeks: 16));
    final list = await repo.getSemesters();
    expect(list.map((s) => s.name).toList(), ['新', '旧']);
  });

  // ---- Course ----

  test('Course CRUD 往返一致（含自定义周序列）', () async {
    final repo = data.timetable;
    final semesterId = await repo.insertSemester(
      Semester(name: '2026 秋', startDate: DateTime(2026, 9, 1), totalWeeks: 16),
    );
    final course = Course(
      semesterId: semesterId,
      name: '高等数学',
      teacher: '王老师',
      location: '教一 101',
      color: '#4C9AFF',
      weekType: WeekType.custom,
      weekList: const [1, 3, 5, 8, 10],
      startWeek: 1,
      endWeek: 16,
      weekday: 1,
      startPeriod: 1,
      endPeriod: 2,
    );
    final id = await repo.insertCourse(course);

    final fetched = await repo.getCourseById(id);
    expect(fetched, course.copyWith(id: id));

    final list = await repo.getCourses(semesterId);
    expect(list, hasLength(1));
    expect(list.first.weekList, [1, 3, 5, 8, 10]);

    final byWeekday = await repo.getCoursesByWeekday(semesterId, 1);
    expect(byWeekday, hasLength(1));

    await repo.updateCourse(course.copyWith(id: id, name: '线性代数'));
    expect((await repo.getCourseById(id))!.name, '线性代数');

    expect(await repo.deleteCourse(id), 1);
    expect(await repo.getCourses(semesterId), isEmpty);
  });

  test('getAllCourses 返回全部学期课程', () async {
    final repo = data.timetable;
    final s1 = await repo.insertSemester(
      Semester(name: 'A', startDate: DateTime(2026, 9, 1), totalWeeks: 16),
    );
    final s2 = await repo.insertSemester(
      Semester(name: 'B', startDate: DateTime(2027, 9, 1), totalWeeks: 16),
    );
    await repo.insertCourse(Course(semesterId: s1, name: 'C1', weekday: 1, startPeriod: 1, endPeriod: 2));
    await repo.insertCourse(Course(semesterId: s2, name: 'C2', weekday: 2, startPeriod: 3, endPeriod: 4));
    expect(await repo.getAllCourses(), hasLength(2));
  });

  // ---- Period ----

  test('Period CRUD 往返一致', () async {
    final repo = data.timetable;
    final period = Period(index: 1, startTime: '08:00', endTime: '08:45');
    final id = await repo.insertPeriod(period);

    expect(await repo.getPeriods(), hasLength(1));
    expect(await repo.getPeriods().then((p) => p.first), period.copyWith(id: id));

    await repo.updatePeriod(period.copyWith(id: id, startTime: '08:05'));
    expect((await repo.getPeriods()).first.startTime, '08:05');

    expect(await repo.deletePeriod(id), 1);
    expect(await repo.getPeriods(), isEmpty);
  });

  test('replacePeriods 整体替换节次表', () async {
    final repo = data.timetable;
    await repo.insertPeriod(Period(index: 1, startTime: '08:00', endTime: '08:45'));
    await repo.replacePeriods([
      Period(index: 1, startTime: '08:30', endTime: '09:15'),
      Period(index: 2, startTime: '09:25', endTime: '10:10'),
    ]);
    final periods = await repo.getPeriods();
    expect(periods, hasLength(2));
    expect(periods.map((p) => p.index).toList(), [1, 2]);
    expect(periods.first.startTime, '08:30');
  });

  // ---- Holiday ----

  test('Holiday CRUD 与日期/课程过滤', () async {
    final repo = data.timetable;
    final semesterId = await repo.insertSemester(
      Semester(name: '2026 秋', startDate: DateTime(2026, 9, 1), totalWeeks: 16),
    );
    final courseId = await repo.insertCourse(
      Course(semesterId: semesterId, name: '高数', weekday: 1, startPeriod: 1, endPeriod: 2),
    );
    final h1 = Holiday(date: DateTime(2026, 10, 1), reason: '国庆');
    final h2 = Holiday(date: DateTime(2026, 10, 5), courseId: courseId, reason: '调停课');
    final id1 = await repo.insertHoliday(h1);
    final id2 = await repo.insertHoliday(h2);

    expect(await repo.getHolidays(), hasLength(2));
    expect(await repo.getHolidays(courseId: courseId), hasLength(1));
    expect(
      await repo.getHolidays(from: DateTime(2026, 10, 2), to: DateTime(2026, 10, 6)),
      hasLength(1),
    );

    final fetched = await repo.getHolidays().then((list) => list.firstWhere((e) => e.id == id2));
    expect(fetched, h2.copyWith(id: id2));

    expect(await repo.deleteHoliday(id1), 1);
    expect(await repo.getHolidays(), hasLength(1));
  });
}
