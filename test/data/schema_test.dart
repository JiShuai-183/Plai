import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/db/db_schema.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/holiday.dart';
import 'package:plai/data/models/semester.dart';
import 'package:plai/data/models/task.dart';

import 'test_helpers.dart';

void main() {
  late TestData data;

  setUp(() async {
    data = await TestData.create();
  });

  tearDown(() async {
    await data.db.close();
  });

  test('onCreate 建出全部 6 张表', () async {
    final db = await data.db.database;
    const tables = <String>[
      DbTables.semester,
      DbTables.course,
      DbTables.period,
      DbTables.holiday,
      DbTables.task,
      DbTables.setting,
    ];
    for (final table in tables) {
      final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [table],
      );
      expect(rows, hasLength(1), reason: '表 $table 应存在');
    }
  });

  test('course 表含 PRD 全字段', () async {
    final db = await data.db.database;
    final cols = await db.rawQuery('PRAGMA table_info(${DbTables.course})');
    final names = cols.map((c) => c['name']).toSet();
    expect(
      names,
      containsAll(<String>[
        'id', 'semester_id', 'name', 'teacher', 'location', 'color',
        'week_type', 'week_list', 'start_week', 'end_week',
        'weekday', 'start_period', 'end_period',
      ]),
    );
  });

  test('task 表含 PRD 全字段', () async {
    final db = await data.db.database;
    final cols = await db.rawQuery('PRAGMA table_info(${DbTables.task})');
    final names = cols.map((c) => c['name']).toSet();
    expect(
      names,
      containsAll(<String>[
        'id', 'title', 'description', 'type', 'due_date', 'due_time',
        'priority', 'course_id', 'remind_offset_min', 'remind_date',
        'completed', 'completed_at', 'created_at',
      ]),
    );
  });

  test('外键级联：删学期 → 删课程 → 删停课、任务 courseId 置空', () async {
    final db = await data.db.database;
    final semesterId = await data.timetable.insertSemester(
      Semester(name: '2026 秋', startDate: DateTime(2026, 9, 1), totalWeeks: 16),
    );
    final courseId = await data.timetable.insertCourse(
      Course(
        semesterId: semesterId,
        name: '高等数学',
        weekday: 1,
        startPeriod: 1,
        endPeriod: 2,
      ),
    );
    await data.timetable.insertHoliday(
      Holiday(date: DateTime(2026, 9, 7), courseId: courseId, reason: '停课'),
    );
    final taskId = await data.tasks.insertTask(
      Task(
        title: '高数作业',
        type: TaskType.todo,
        dueDate: DateTime(2026, 9, 10),
        courseId: courseId,
      ),
    );

    expect(await data.timetable.deleteSemester(semesterId), 1);

    final courseRows = await db.query(
      DbTables.course,
      where: 'semester_id = ?',
      whereArgs: [semesterId],
    );
    final holidayRows = await db.query(
      DbTables.holiday,
      where: 'course_id = ?',
      whereArgs: [courseId],
    );
    expect(courseRows, isEmpty);
    expect(holidayRows, isEmpty);

    final task = await data.tasks.getTaskById(taskId);
    expect(task, isNotNull);
    expect(task!.courseId, isNull);
  });
}
