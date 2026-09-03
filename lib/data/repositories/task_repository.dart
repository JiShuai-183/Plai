import 'package:sqflite/sqflite.dart';

import '../db/app_database.dart';
import '../db/db_schema.dart';
import '../models/date_utils.dart';
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

  /// 删除任务，返回受影响行数（daily 打卡记录随之级联删除）。
  Future<int> deleteTask(int id);

  /// 快速标记/取消完成；完成时自动写入完成时间，取消时清空。
  /// 语义仅用于非 daily 类型（scheduled/todo/span）；daily 走打卡接口。
  Future<int> setCompleted(int id, bool completed);

  /// 每日打卡：把某任务某天标记为已打卡（幂等，重复标记不报错）。
  Future<void> markDailyCompleted(int taskId, DateTime date);

  /// 每日打卡：取消某任务某天的已打卡记录。
  Future<void> clearDailyCompleted(int taskId, DateTime date);

  /// 某任务某天是否已打卡。
  Future<bool> isDailyCompleted(int taskId, DateTime date);

  /// 某任务全部已打卡日期（按日期升序）。
  Future<List<DateTime>> dailyLogsFor(int taskId);
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

  // ---- 每日打卡（task_daily_logs） ----

  @override
  Future<void> markDailyCompleted(int taskId, DateTime date) async {
    final db = await _database;
    await db.insert(
      DbTables.taskDailyLog,
      {
        'task_id': taskId,
        'date': _dateOnly(date),
        'completed_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  @override
  Future<void> clearDailyCompleted(int taskId, DateTime date) async {
    final db = await _database;
    await db.delete(
      DbTables.taskDailyLog,
      where: 'task_id = ? AND date = ?',
      whereArgs: [taskId, _dateOnly(date)],
    );
  }

  @override
  Future<bool> isDailyCompleted(int taskId, DateTime date) async {
    final db = await _database;
    final rows = await db.query(
      DbTables.taskDailyLog,
      columns: ['id'],
      where: 'task_id = ? AND date = ?',
      whereArgs: [taskId, _dateOnly(date)],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<List<DateTime>> dailyLogsFor(int taskId) async {
    final db = await _database;
    final rows = await db.query(
      DbTables.taskDailyLog,
      columns: ['date'],
      where: 'task_id = ?',
      whereArgs: [taskId],
      orderBy: 'date ASC',
    );
    return rows
        .map((r) => stringToDateOnly(r['date'] as String))
        .toList(growable: false);
  }

  static String _dateOnly(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }
}
