import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/db/db_schema.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// V1 的 task 建表 DDL（不含 start_date，用于模拟升级前的旧库）。
const String _v1TaskDdl = '''
CREATE TABLE task (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  type TEXT NOT NULL,
  due_date TEXT NOT NULL,
  due_time TEXT,
  priority TEXT NOT NULL DEFAULT 'normal',
  course_id INTEGER REFERENCES course(id) ON DELETE SET NULL,
  remind_offset_min INTEGER,
  remind_date TEXT,
  completed INTEGER NOT NULL DEFAULT 0,
  completed_at TEXT,
  created_at TEXT NOT NULL
)''';

void main() {
  sqfliteFfiInit();

  test('V1 → 当前版本迁移：老数据保留，task 补 start_date / daily_remind_time，新增 task_daily_logs', () async {
    final dir = await Directory.systemTemp.createTemp('plai_mig');
    final path = p.join(dir.path, 'mig.db');
    try {
      // 建一个版本 1 的旧库，塞入老任务数据。
      final v1 = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          singleInstance: false,
          onCreate: (db, _) async => db.execute(_v1TaskDdl),
        ),
      );
      await v1.insert('task', {
        'title': '老任务',
        'description': '',
        'type': TaskType.todo.code,
        'due_date': '2026-10-01',
        'completed': 0,
        'created_at': DateTime(2026, 9, 1).toIso8601String(),
      });
      await v1.close();

      // 用 AppDatabase（当前 dbVersion）重开同一文件 → 触发 onUpgrade 1→当前。
      final migrated = AppDatabase(factory: databaseFactoryFfi, path: path);
      try {
        final db = await migrated.database;

        // 老数据保留。
        final rows = await db.query(DbTables.task);
        expect(rows, hasLength(1));
        expect(rows.first['title'], '老任务');

        // task 补了可空 start_date / daily_remind_time，老行读 null。
        final cols = await db.rawQuery('PRAGMA table_info(${DbTables.task})');
        expect(cols.map((c) => c['name']), contains('start_date'));
        expect(cols.map((c) => c['name']), contains('daily_remind_time'));
        expect(rows.first['start_date'], isNull);
        expect(rows.first['daily_remind_time'], isNull);

        // task_daily_logs 已建且可写。
        final tables = await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
            [DbTables.taskDailyLog]);
        expect(tables, hasLength(1));

        final repo = TaskRepository(migrated);
        final task = await repo.getTaskById(rows.first['id'] as int);
        expect(task, isNotNull);
        expect(task!.startDate, isNull);

        await repo.markDailyCompleted(task.id!, DateTime(2026, 10, 2));
        expect(await repo.isDailyCompleted(task.id!, DateTime(2026, 10, 2)), isTrue);
      } finally {
        await migrated.close();
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
