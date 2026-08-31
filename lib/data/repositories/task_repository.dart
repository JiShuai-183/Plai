import 'package:sqflite/sqflite.dart';

import '../db/app_database.dart';
import '../db/db_schema.dart';
import '../models/task.dart';

/// 日程/任务域 Repository 接口：task CRUD 契约。
///
/// feature agent 只依赖本接口，实现见 [TaskRepository]。
abstract class ITaskRepository {
  /// 查询任务；可按类型、完成状态、截止日期范围过滤（全空则返回全部）。
  Future<List<Task>> getTasks({
    TaskType? type,
    bool? completed,
    DateTime? from,
    DateTime? to,
  });

  /// 按 id 查询任务，不存在返回 null。
  Future<Task?> getTaskById(int id);

  /// 插入任务（createdAt 为空时自动填当前时间），返回新行自增 id。
  Future<int> insertTask(Task task);

  /// 更新任务，返回受影响行数。
  Future<int> updateTask(Task task);

  /// 删除任务，返回受影响行数。
  Future<int> deleteTask(int id);

  /// 快速标记/取消完成；完成时自动写入完成时间，取消时清空。
  Future<int> setCompleted(int id, bool completed);
}

/// 日程/任务域 Repository 的 sqflite 实现。
class TaskRepository implements ITaskRepository {
  TaskRepository(this._db);

  final AppDatabase _db;

  Future<Database> get _database => _db.database;

  @override
  Future<List<Task>> getTasks({
    TaskType? type,
    bool? completed,
    DateTime? from,
    DateTime? to,
  }) async {
    final db = await _database;
    final where = <String>[];
    final args = <Object?>[];
    if (type != null) {
      where.add('type = ?');
      args.add(type.code);
    }
    if (completed != null) {
      where.add('completed = ?');
      args.add(completed ? 1 : 0);
    }
    if (from != null) {
      where.add('due_date >= ?');
      args.add(_dateOnly(from));
    }
    if (to != null) {
      where.add('due_date <= ?');
      args.add(_dateOnly(to));
    }
    final rows = await db.query(
      DbTables.task,
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'due_date ASC, due_time IS NULL ASC, due_time ASC',
    );
    return rows.map(Task.fromDbMap).toList();
  }

  @override
  Future<Task?> getTaskById(int id) async {
    final db = await _database;
    final rows = await db.query(
      DbTables.task,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Task.fromDbMap(rows.first);
  }

  @override
  Future<int> insertTask(Task task) async {
    final db = await _database;
    final map = task.toDbMap();
    if (map['created_at'] == null) {
      map['created_at'] = DateTime.now().toIso8601String();
    }
    return db.insert(DbTables.task, map);
  }

  @override
  Future<int> updateTask(Task task) async {
    final db = await _database;
    return db.update(
      DbTables.task,
      task.toDbMap(),
      where: 'id = ?',
      whereArgs: [task.id],
    );
  }

  @override
  Future<int> deleteTask(int id) async {
    final db = await _database;
    return db.delete(DbTables.task, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<int> setCompleted(int id, bool completed) async {
    final db = await _database;
    return db.update(
      DbTables.task,
      {
        'completed': completed ? 1 : 0,
        'completed_at': completed ? DateTime.now().toIso8601String() : null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static String _dateOnly(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }
}
