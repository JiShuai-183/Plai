import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/db/db_schema.dart';
import 'package:plai/data/models/task.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  Future<Database> oldDatabase(
    String path, {
    bool invalidCourse = false,
  }) async {
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 7,
        singleInstance: false,
        onCreate: (db, _) async {
          for (final ddl in createTableStatements) {
            await db.execute(
              ddl == createTaskTable
                  ? ddl.replaceFirst(
                      'due_date TEXT,',
                      'due_date TEXT NOT NULL,',
                    )
                  : ddl,
            );
          }
          for (final ddl in createIndexStatements) {
            await db.execute(ddl);
          }
        },
      ),
    );
    await db.insert('semester', {
      'id': 1,
      'name': '学期',
      'start_date': '2026-09-01',
      'total_weeks': 16,
    });
    await db.insert('course', {
      'id': 1,
      'semester_id': 1,
      'name': '课程',
      'weekday': 1,
      'start_period': 1,
      'end_period': 2,
      'week_type': 'every',
      'start_week': 1,
      'end_week': 16,
    });
    await db.insert(
      'task',
      Task(
        id: 7,
        title: '旧任务',
        description: '保留',
        type: TaskType.daily,
        dueDate: DateTime(2026, 12, 1),
        startDate: DateTime(2026, 11, 8),
        courseId: invalidCourse ? 999 : 1,
        imagePaths: const ['managed/photo.png'],
        dailyRemindTime: '08:00',
        reminderRepeat: ReminderRepeat.daily,
      ).toDbMap(),
    );
    await db.insert('task_daily_logs', {
      'id': 9,
      'task_id': 7,
      'date': '2026-11-08',
      'completed_at': '2026-11-08T08:00:00',
    });
    // 已删除的最大ID仍不能在升级后被复用。
    await db.rawUpdate(
      "UPDATE sqlite_sequence SET seq = 70 WHERE name = 'task'",
    );
    await db.rawUpdate(
      "UPDATE sqlite_sequence SET seq = 90 WHERE name = 'task_daily_logs'",
    );
    return db;
  }

  test('V7→V8保留全部任务/日志/序列，外键与幂等重开正常', () async {
    final dir = await Directory.systemTemp.createTemp('plai-v8-');
    final path = '${dir.path}/db';
    final old = await oldDatabase(path);
    final original = await old.query('task');
    final logs = await old.query('task_daily_logs');
    await old.close();
    var app = AppDatabase(factory: databaseFactoryFfi, path: path);
    try {
      var db = await app.database;
      expect(await db.query('task'), original);
      expect(await db.query('task_daily_logs'), logs);
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect(
        (await db.rawQuery('PRAGMA table_info(task)'))
            .singleWhere((c) => c['name'] == 'due_date')['notnull'],
        0,
      );
      expect(
        await db.insert(
          'task',
          Task(title: '无期限', type: TaskType.todo).toDbMap(),
        ),
        71,
      );
      expect(
        await db.insert('task_daily_logs', {
          'task_id': 7,
          'date': '2026-11-09',
        }),
        91,
      );
      await db.delete('course', where: 'id = 1');
      expect(
        (await db.query('task', where: 'id = 7')).single['course_id'],
        isNull,
      );
      // 已可空但版本仍旧的库，重跑升级不应重建或丢日志。
      await db.setVersion(7);
      await app.close();
      app = AppDatabase(factory: databaseFactoryFfi, path: path);
      db = await app.database;
      expect(await db.query('task_daily_logs'), hasLength(2));
      await db.delete('task', where: 'id = 7');
      expect(await db.query('task_daily_logs'), isEmpty);
    } finally {
      await app.close();
      await dir.delete(recursive: true);
    }
  });

  test('迁移失败回滚保留原版本、NOT NULL、照片与子表日志', () async {
    final dir = await Directory.systemTemp.createTemp('plai-v8-rollback-');
    final path = '${dir.path}/db';
    final old = await oldDatabase(path, invalidCourse: true);
    final tasks = await old.query('task');
    final logs = await old.query('task_daily_logs');
    await old.close();
    final app = AppDatabase(factory: databaseFactoryFfi, path: path);
    try {
      await expectLater(app.database, throwsA(anything));
      final unchanged = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      try {
        expect(await unchanged.getVersion(), 7);
        expect(await unchanged.query('task'), tasks);
        expect(await unchanged.query('task_daily_logs'), logs);
        expect(
          (await unchanged.rawQuery('PRAGMA table_info(task)'))
              .singleWhere((c) => c['name'] == 'due_date')['notnull'],
          1,
        );
        expect(
          await unchanged.rawQuery(
            "SELECT name FROM sqlite_master WHERE name = 'task_v8'",
          ),
          isEmpty,
        );
      } finally {
        await unchanged.close();
      }
    } finally {
      await app.close();
      await dir.delete(recursive: true);
    }
  });
}
