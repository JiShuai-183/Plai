import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/backup/backup_service.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/holiday.dart';
import 'package:plai/data/models/period.dart';
import 'package:plai/data/models/semester.dart';
import 'package:plai/data/models/task.dart';

import 'test_helpers.dart';

Future<BackupService> _service(TestData data) => Future.value(
      BackupService(
        db: data.db,
        timetable: data.timetable,
        tasks: data.tasks,
        settings: data.settings,
      ),
    );

/// 往库里塞一套样例数据。
Future<void> _seed(TestData data) async {
  final semesterId = await data.timetable.insertSemester(
    Semester(name: '2026 秋', startDate: DateTime(2026, 9, 1), totalWeeks: 16),
  );
  await data.timetable.insertPeriod(Period(index: 1, startTime: '08:00', endTime: '08:45'));
  final courseId = await data.timetable.insertCourse(
    Course(semesterId: semesterId, name: '高等数学', weekday: 1, startPeriod: 1, endPeriod: 2),
  );
  await data.timetable.insertHoliday(Holiday(date: DateTime(2026, 10, 1), courseId: courseId, reason: '国庆'));
  await data.tasks.insertTask(
    Task(title: '交作业', type: TaskType.todo, dueDate: DateTime(2026, 10, 1), courseId: courseId),
  );
  await data.settings.setValue('remind_minutes', '10');
}

void main() {
  test('导出 → 覆盖恢复 → 再导出，data 数据块完全一致', () async {
    final source = await TestData.create();
    final target = await TestData.create();
    try {
      await _seed(source);

      final backupJson = await (await _service(source)).exportToJson();

      await (await _service(target)).restore(backupJson, strategy: RestoreStrategy.overwrite);

      final reExport = await (await _service(target)).exportToJson();
      expect(reExport['data'], backupJson['data']);

      // 关键维度核对。
      expect(await target.timetable.getSemesters(), hasLength(1));
      expect(await target.timetable.getCoursesByWeekday(1, 1), hasLength(1));
      expect(await target.tasks.getTasks(), hasLength(1));
      expect(await target.settings.getValue('remind_minutes'), '10');
    } finally {
      await source.db.close();
      await target.db.close();
    }
  });

  test('preview 返回各表数量摘要', () async {
    final source = await TestData.create();
    try {
      await _seed(source);
      final backupJson = await (await _service(source)).exportToJson();
      final preview = (await _service(source)).preview(backupJson);
      expect(preview.semesterCount, 1);
      expect(preview.courseCount, 1);
      expect(preview.periodCount, 1);
      expect(preview.holidayCount, 1);
      expect(preview.taskCount, 1);
      expect(preview.settingCount, 1);
      expect(preview.exportedAt, isNotNull);
    } finally {
      await source.db.close();
    }
  });

  test('合并恢复：学期按名称、任务按 标题+日期 去重，课程并入', () async {
    final source = await TestData.create();
    final target = await TestData.create();
    try {
      await _seed(source);

      // 目标库已有同名学期、同名任务，以及一门旧课程。
      final targetSemesterId = await target.timetable.insertSemester(
        Semester(name: '2026 秋', startDate: DateTime(2026, 9, 1), totalWeeks: 16),
      );
      await target.timetable.insertCourse(
        Course(semesterId: targetSemesterId, name: '旧课程', weekday: 5, startPeriod: 5, endPeriod: 6),
      );
      await target.tasks.insertTask(
        Task(title: '交作业', type: TaskType.todo, dueDate: DateTime(2026, 10, 1)),
      );

      final backupJson = await (await _service(source)).exportToJson();
      await (await _service(target)).restore(backupJson, strategy: RestoreStrategy.merge);

      expect(await target.timetable.getSemesters(), hasLength(1), reason: '学期按名称去重');
      final courses = await target.timetable.getAllCourses();
      expect(courses.map((c) => c.name).toSet(), {'旧课程', '高等数学'}, reason: '课程并入且不重复');
      expect(await target.tasks.getTasks(), hasLength(1), reason: '任务按标题+日期去重');
      expect(await target.settings.getValue('remind_minutes'), '10', reason: '设置备份优先');
    } finally {
      await source.db.close();
      await target.db.close();
    }
  });

  test('.plai 文件导出→读取往返一致', () async {
    final source = await TestData.create();
    try {
      await _seed(source);
      final dir = await Directory.systemTemp.createTemp('plai_backup');
      final file = '${dir.path}/backup.plai';
      try {
        final service = await _service(source);
        await service.exportToFile(file);
        final readBack = await service.readFile(file);
        expect(readBack['format'], PlaiBackupFormat.format);
        expect(readBack['version'], PlaiBackupFormat.version);
        final content = jsonDecode(await File(file).readAsString(encoding: utf8)) as Map<String, dynamic>;
        expect(content['data'], readBack['data']);
      } finally {
        await dir.delete(recursive: true);
      }
    } finally {
      await source.db.close();
    }
  });

  test('格式非法的备份 → 抛 BackupFormatException', () async {
    final target = await TestData.create();
    try {
      await expectLater(
        (await _service(target)).restore(
          {'format': 'unknown', 'version': 1, 'data': {}},
          strategy: RestoreStrategy.overwrite,
        ),
        throwsA(isA<BackupFormatException>()),
      );
    } finally {
      await target.db.close();
    }
  });
}
