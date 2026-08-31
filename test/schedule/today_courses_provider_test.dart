import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/period.dart';
import 'package:plai/data/models/semester.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:plai/features/schedule/schedule_providers.dart';
import 'package:plai/features/timetable/timetable_providers.dart';

import '../data/test_helpers.dart';

void main() {
  late TestData data;
  late ITimetableRepository repo;

  setUp(() async {
    data = await TestData.create();
    repo = data.timetable;
  });

  tearDown(() async {
    await data.db.close();
  });

  /// 以「今天」为基准构造数据，读 [todayCoursesProvider]。
  Future<List<TodayCourse>> readToday() async {
    final ProviderContainer container = ProviderContainer(
      overrides: [timetableRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    return container.read(todayCoursesProvider.future);
  }

  group('todayCoursesProvider', () {
    test('今天在学期内：今日有课课程正常展示', () async {
      final DateTime today = DateTime.now();
      final int semesterId = await repo.insertSemester(
        Semester(name: '本周学期', startDate: today, totalWeeks: 8),
      );
      await repo.insertPeriod(
        Period(index: 1, startTime: '08:00', endTime: '08:45'),
      );
      await repo.insertCourse(
        Course(
          semesterId: semesterId,
          name: '今日课',
          weekday: today.weekday,
          startPeriod: 1,
          endPeriod: 1,
          weekType: WeekType.every,
          startWeek: 1,
          endWeek: 8,
        ),
      );

      final List<TodayCourse> courses = await readToday();

      expect(courses, hasLength(1));
      expect(courses.first.course.name, '今日课');
      expect(courses.first.week, 1); // 开学日即今天 → 第 1 周
      expect(courses.first.startTime?.hour, 8);
    });

    test('开学前（未来学期）：不把未来周的课误标为今日课程', () async {
      final DateTime today = DateTime.now();
      await repo.insertSemester(
        Semester(name: '下月开学', startDate: today.add(const Duration(days: 30)), totalWeeks: 8),
      );
      await repo.insertPeriod(
        Period(index: 1, startTime: '08:00', endTime: '08:45'),
      );

      final List<TodayCourse> courses = await readToday();

      expect(courses, isEmpty);
    });

    test('已结课（过去学期）：不把历史周的课误标为今日课程', () async {
      final DateTime today = DateTime.now();
      final int semesterId = await repo.insertSemester(
        Semester(name: '已结课', startDate: today.subtract(const Duration(days: 60)), totalWeeks: 8),
      );
      await repo.insertPeriod(
        Period(index: 1, startTime: '08:00', endTime: '08:45'),
      );
      await repo.insertCourse(
        Course(
          semesterId: semesterId,
          name: '历史课',
          weekday: today.weekday,
          startPeriod: 1,
          endPeriod: 1,
          weekType: WeekType.every,
          startWeek: 1,
          endWeek: 8,
        ),
      );

      final List<TodayCourse> courses = await readToday();

      expect(courses, isEmpty);
    });
  });
}
