import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/backup/backup_service.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/period.dart';
import 'package:plai/data/models/semester.dart';

import 'test_helpers.dart';

BackupService _service(TestData data) => BackupService(
  db: data.db,
  timetable: data.timetable,
  tasks: data.tasks,
  settings: data.settings,
);

/// 回归：真机上报的 DatabaseException(FOREIGN KEY constraint failed, code 787)。
///
/// 根因：覆盖恢复把学期/课程都以自增方式重新插入（不沿用备份 id），但 SQLite 的
/// AUTOINCREMENT 计数器不会因为 DELETE 而归零。只要本机此前存过数据，新学期就会
/// 拿到比备份更大的 id，而课程仍写备份里的旧 semester_id → 外键不存在 → 787。
void main() {
  test('覆盖恢复：本机已有历史数据时，课程外键必须重新映射而不是照抄备份 id', () async {
    final source = await TestData.create();
    final target = await TestData.create();
    try {
      final int backupSemesterId = await source.timetable.insertSemester(
        Semester(
          name: '2026 秋',
          startDate: DateTime(2026, 9, 1),
          totalWeeks: 16,
        ),
      );
      expect(backupSemesterId, 1);
      await source.timetable.insertPeriod(
        Period(index: 1, startTime: '08:00', endTime: '08:45'),
      );
      await source.timetable.insertCourse(
        Course(
          semesterId: backupSemesterId,
          name: '理论力学',
          teacher: '姬振华',
          location: '07C105',
          weekday: 1,
          startPeriod: 1,
          endPeriod: 2,
        ),
      );
      final Map<String, dynamic> backupJson = await _service(source).exportToJson();

      // 制造与本机真机一致的形态：先写入再清空，让 AUTOINCREMENT 计数器前进。
      await target.timetable.insertSemester(
        Semester(
          name: '旧学期',
          startDate: DateTime(2025, 9, 1),
          totalWeeks: 18,
        ),
      );
      final db = await target.db.database;
      await db.delete('course');
      await db.delete('semester');

      await _service(
        target,
      ).restore(backupJson, strategy: RestoreStrategy.overwrite);

      final semesters = await target.timetable.getSemesters();
      expect(semesters, hasLength(1));
      final courses = await target.timetable.getAllCourses();
      expect(courses, hasLength(1));
      // 关键断言：课程外键指向恢复后真实存在的学期，而不是备份里的 1。
      expect(courses.single.semesterId, semesters.single.id);
      expect(courses.single.name, '理论力学');
    } finally {
      await source.db.close();
      await target.db.close();
    }
  });
}
