import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/import_export/timetable_import_export.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/semester.dart';

import 'test_helpers.dart';

const _validJson = '''
{
  "semester": {"name": "2026 秋", "startDate": "2026-09-01", "totalWeeks": 16},
  "periods": [
    {"index": 1, "startTime": "08:00", "endTime": "08:45"},
    {"index": 2, "startTime": "08:55", "endTime": "09:40"}
  ],
  "courses": [
    {"name": "高等数学", "teacher": "王老师", "location": "教一101",
     "color": "#4c9aff", "weekType": "every", "weekList": [],
     "startWeek": 1, "endWeek": 16, "weekday": 1, "startPeriod": 1, "endPeriod": 2},
    {"name": "英语", "teacher": "李老师",
     "weekType": "custom", "weekList": [1, 3, 5],
     "startWeek": 1, "endWeek": 12, "weekday": 3, "startPeriod": 3, "endPeriod": 4}
  ]
}
''';

void main() {
  late TestData data;
  late TimetableImportExport io;

  setUp(() async {
    data = await TestData.create();
    io = TimetableImportExport(db: data.db, timetable: data.timetable);
  });

  tearDown(() async {
    await data.db.close();
  });

  group('JSON 导入', () {
    test('合法 JSON 新建学期并写入课程/节次', () async {
      final result = await io.importJson(_validJson, strategy: ImportStrategy.overwrite);

      expect(result.semesterId, greaterThan(0));
      expect(result.periodsImported, 2);
      expect(result.coursesImported, 2);

      final semesters = await data.timetable.getSemesters();
      expect(semesters, hasLength(1));
      expect(semesters.first.name, '2026 秋');

      final periods = await data.timetable.getPeriods();
      expect(periods, hasLength(2));

      final courses = await data.timetable.getCourses(result.semesterId);
      expect(courses, hasLength(2));
      final customCourse = courses.firstWhere((c) => c.name == '英语');
      expect(customCourse.weekType.name, 'custom');
      expect(customCourse.weekList, [1, 3, 5]);
      // 颜色归一化为大写 #RRGGBB。
      expect(courses.firstWhere((c) => c.name == '高等数学').color, '#4C9AFF');
    });

    test('非法课程字段 → 整体失败并提示行号，不做部分写入', () async {
      const bad = '''
      {"semester": {"name": "X", "startDate": "2026-09-01", "totalWeeks": 16},
       "periods": [],
       "courses": [
         {"name": "好课", "weekType": "every", "startWeek": 1, "endWeek": 16,
          "weekday": 1, "startPeriod": 1, "endPeriod": 2},
         {"name": "坏课", "weekType": "every", "startWeek": 1, "endWeek": 16,
          "weekday": 9, "startPeriod": 1, "endPeriod": 2}
       ]}
      ''';
      await expectLater(
        io.importJson(bad, strategy: ImportStrategy.overwrite),
        throwsA(isA<TimetableImportException>()
            .having((e) => e.errors, 'errors', isNotEmpty)
            .having((e) => e.errors.first.row, 'row', 2)),
      );
      expect(await data.timetable.getSemesters(), isEmpty);
    });

    test('缺少 semester 块 → 结构错误', () async {
      await expectLater(
        io.importJson('{"courses": []}', strategy: ImportStrategy.overwrite),
        throwsA(isA<TimetableImportException>()
            .having((e) => e.errors.first.message, 'msg', contains('semester'))),
      );
    });

    test('节次时间非法/序号重复 → 行号错误', () async {
      const bad = '''
      {"semester": {"name": "X", "startDate": "2026-09-01", "totalWeeks": 16},
       "periods": [
         {"index": 1, "startTime": "08:00", "endTime": "08:45"},
         {"index": 1, "startTime": "99:00", "endTime": "08:45"}
       ],
       "courses": []}
      ''';
      await expectLater(
        io.importJson(bad, strategy: ImportStrategy.merge),
        throwsA(isA<TimetableImportException>()
            .having((e) => e.errors, 'errors', hasLength(greaterThanOrEqualTo(2)))),
      );
    });

    test('导入到已存在学期：覆盖/合并策略', () async {
      final semesterId = await data.timetable.insertSemester(
        Semester(name: '2026 秋', startDate: DateTime(2026, 9, 1), totalWeeks: 16),
      );
      await data.timetable.insertCourse(
        Course(semesterId: semesterId, name: '旧课程', weekday: 2, startPeriod: 1, endPeriod: 2),
      );

      final result = await io.importJson(
        _validJson,
        targetSemesterId: semesterId,
        strategy: ImportStrategy.overwrite,
      );
      expect(result.semesterId, semesterId);
      final courses = await data.timetable.getCourses(semesterId);
      expect(courses.map((c) => c.name).toList(), containsAll(['高等数学', '英语']));
      expect(courses.map((c) => c.name).toList(), isNot(contains('旧课程')));
    });
  });

  group('CSV 导入', () {
    test('合法 CSV 导入课程（含自定义周序列）', () async {
      final semesterId = await data.timetable.insertSemester(
        Semester(name: '2026 秋', startDate: DateTime(2026, 9, 1), totalWeeks: 16),
      );
      const csv = '课程名,教师,地点,星期,开始节次,结束节次,周次类型,开始周,结束周,自定义周序列,颜色\n'
          '高等数学,王老师,教一101,1,1,2,every,1,16,,#4C9AFF\n'
          '英语,李老师,,3,3,4,custom,1,12,"1,3,5",#00FF00\n';
      final result = await io.importCsv(csv, semesterId: semesterId, strategy: ImportStrategy.merge);
      expect(result.coursesImported, 2);

      final courses = await data.timetable.getCourses(semesterId);
      final english = courses.firstWhere((c) => c.name == '英语');
      expect(english.weekList, [1, 3, 5]);
    });

    test('缺少必填列 → 错误', () async {
      const csv = '课程名,教师\n高等数学,王老师\n';
      await expectLater(
        io.importCsv(csv, semesterId: 1, strategy: ImportStrategy.merge),
        throwsA(isA<TimetableImportException>()
            .having((e) => e.errors.first.message, 'msg', contains('缺少必填列'))),
      );
    });

    test('周次类型非法 → 行号错误', () async {
      const csv = '课程名,星期,开始节次,结束节次,周次类型,开始周,结束周\n'
          '高等数学,1,1,2,每学期,1,16\n';
      await expectLater(
        io.importCsv(csv, semesterId: 1, strategy: ImportStrategy.merge),
        throwsA(isA<TimetableImportException>()
            .having((e) => e.errors.first.row, 'row', 2)),
      );
    });

    test('星期越界 → 行号错误', () async {
      const csv = '课程名,星期,开始节次,结束节次,周次类型,开始周,结束周\n'
          '高等数学,0,1,2,every,1,16\n';
      await expectLater(
        io.importCsv(csv, semesterId: 1, strategy: ImportStrategy.merge),
        throwsA(isA<TimetableImportException>()
            .having((e) => e.errors, 'errors', hasLength(1))),
      );
    });
  });

  group('导出', () {
    test('exportJson 结构与导入一致（往返）', () async {
      final imported = await io.importJson(_validJson, strategy: ImportStrategy.overwrite);
      final exported = jsonDecode(await io.exportJson(imported.semesterId));
      final root = exported as Map<String, dynamic>;

      expect((root['semester'] as Map)['name'], '2026 秋');
      expect(root['periods'], hasLength(2));
      expect(root['courses'], hasLength(2));
      expect((root['courses'] as List).first, isA<Map>());
    });

    test('exportCsv 输出合法表头与行', () async {
      final imported = await io.importJson(_validJson, strategy: ImportStrategy.overwrite);
      final csv = await io.exportCsv(imported.semesterId);
      final lines = csv.trim().split('\n');
      expect(lines.first, contains('课程名'));
      expect(lines, hasLength(3)); // 表头 + 2 门课
      expect(lines.last, contains('英语'));
    });
  });

  group('文件读写', () {
    test('exportJsonToFile / importJsonFromFile 往返', () async {
      final imported = await io.importJson(_validJson, strategy: ImportStrategy.overwrite);
      final dir = await Directory.systemTemp.createTemp('plai_test');
      final file = '${dir.path}/timetable.json';
      try {
        await io.exportJsonToFile(imported.semesterId, file);
        final again = await io.importJsonFromFile(
          file,
          targetSemesterId: imported.semesterId,
          strategy: ImportStrategy.overwrite,
        );
        expect(again.coursesImported, 2);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
