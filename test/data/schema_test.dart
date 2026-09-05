import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/db/db_schema.dart';
import 'package:plai/data/models/course.dart';
import 'package:sqflite/sqflite.dart';
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

  test('onCreate 建出全部 9 张表', () async {
    final db = await data.db.database;
    const tables = <String>[
      DbTables.semester,
      DbTables.course,
      DbTables.period,
      DbTables.holiday,
      DbTables.task,
      DbTables.taskDailyLog,
      DbTables.setting,
      DbTables.chatSession,
      DbTables.chatMessage,
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
        'completed', 'completed_at', 'created_at', 'start_date',
      ]),
    );
  });

  test('task_daily_logs 表结构：列 + (task_id,date) 唯一', () async {
    final db = await data.db.database;
    final cols = await db.rawQuery('PRAGMA table_info(${DbTables.taskDailyLog})');
    final names = cols.map((c) => c['name']).toSet();
    expect(names, containsAll(<String>['id', 'task_id', 'date', 'completed_at']));

    final taskId = await data.tasks.insertTask(
      Task(title: '背单词', type: TaskType.daily, dueDate: DateTime(2026, 9, 30)),
    );
    final dbMap = {'task_id': taskId, 'date': '2026-09-03', 'completed_at': null};
    await db.insert(DbTables.taskDailyLog, dbMap);
    // 同 (task_id,date) 冲突：INSERT OR IGNORE 吞掉重复，行数仍为 1。
    await db.insert(DbTables.taskDailyLog, dbMap,
        conflictAlgorithm: ConflictAlgorithm.ignore);
    final rows =
        await db.query(DbTables.taskDailyLog, where: 'task_id = ?', whereArgs: [taskId]);
    expect(rows, hasLength(1));
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

  test('chat_session 表含 PRD 全字段', () async {
    final db = await data.db.database;
    final cols = await db.rawQuery('PRAGMA table_info(${DbTables.chatSession})');
    final names = cols.map((c) => c['name']).toSet();
    expect(
      names,
      containsAll(<String>['id', 'title', 'created_at', 'last_active_at', 'pinned']),
    );
  });

  test('chat_message 表含 PRD 全字段', () async {
    final db = await data.db.database;
    final cols = await db.rawQuery('PRAGMA table_info(${DbTables.chatMessage})');
    final names = cols.map((c) => c['name']).toSet();
    expect(
      names,
      containsAll(<String>[
        'id', 'session_id', 'role', 'content', 'has_context',
        'attachments', 'tool_data', 'created_at',
      ]),
    );

    // session_id 上有索引（查询性能）。
    final indexes = await db.rawQuery(
        'PRAGMA index_list(${DbTables.chatMessage})');
    expect(indexes.map((i) => i['name']), contains('idx_chat_message_session'));
  });

  test('外键级联：删会话 → 其全部消息一并删除', () async {
    final db = await data.db.database;
    final sessionId = await db.insert(DbTables.chatSession, {
      'title': '会话',
      'created_at': DateTime.now().toIso8601String(),
      'last_active_at': DateTime.now().toIso8601String(),
      'pinned': 0,
    });
    await db.insert(DbTables.chatMessage, {
      'session_id': sessionId,
      'role': 'user',
      'content': '你好',
      'has_context': 0,
      'created_at': DateTime.now().toIso8601String(),
    });
    await db.insert(DbTables.chatMessage, {
      'session_id': sessionId,
      'role': 'assistant',
      'content': '嗨',
      'has_context': 0,
      'created_at': DateTime.now().toIso8601String(),
    });
    expect(await db.delete(DbTables.chatSession, where: 'id = ?', whereArgs: [sessionId]), 1);

    final msgRows = await db.query(DbTables.chatMessage,
        where: 'session_id = ?', whereArgs: [sessionId]);
    expect(msgRows, isEmpty);
  });
}
