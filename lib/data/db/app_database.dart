import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'db_schema.dart';

/// 当前数据库版本。V1 = 1；V2 = 2（task 补 start_date、新增 task_daily_logs）；
/// V3 = 3（新增 chat_session / chat_message，AI 对话历史）；
/// V4 = 4（task 补 daily_remind_time，每日打卡每日提醒时刻）；
/// V5 = 5（task 补 reminder_repeat / remind_once_at，提醒「每天 / 不重复」）。
/// V6 = 6（chat_queue，跨会话持久串行队列）。
/// V7 = 7（task.image_paths，日程描述照片）。
/// V8 = 8（task.due_date 可空，无期限待办与长期打卡）。
/// 此后每加表/改表递增并补充 onUpgrade 迁移。
const int dbVersion = 8;

/// 数据库连接与迁移管理（单例）。
///
/// - 生产：`AppDatabase.instance`（打开 App 私有目录下 `plai.db`）。
/// - 测试：`AppDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath)`。
///
/// 打开时自动执行 `PRAGMA foreign_keys = ON`，保证外键级联生效。
class AppDatabase {
  AppDatabase({this.factory, this.path});

  static AppDatabase? _instance;

  /// 全局单例（生产用）。
  static AppDatabase get instance => _instance ??= AppDatabase();

  /// 可注入的数据库工厂（测试传 ffi 工厂；生产为空用全局默认）。
  final DatabaseFactory? factory;

  /// 数据库文件路径（测试传 inMemoryDatabasePath；生产为空用默认路径）。
  final String? path;

  Database? _db;

  /// 正在打开中的连接（in-flight）。首启时多个 provider 会并发首次取库，
  /// 缓存该 Future 让后来者共享同一次 `openDatabase`——否则每路都各开一次，
  /// 首装（库文件不存在）时会重复跑建表 DDL 并争抢文件锁，表现为首次启动卡顿。
  Future<Database>? _opening;

  /// 获取数据库连接（懒加载：首次调用时建库并跑迁移）。
  Future<Database> get database async {
    final current = _db;
    if (current != null && current.isOpen) return current;
    return _opening ??= _open();
  }

  Future<Database> _open() async {
    final factoryToUse = factory ?? databaseFactory;
    final pathToUse = path ?? p.join(await getDatabasesPath(), 'plai.db');
    try {
      final opened = await factoryToUse.openDatabase(
        pathToUse,
        options: OpenDatabaseOptions(
          version: dbVersion,
          // 默认工厂按路径缓存连接，导致不同 AppDatabase（测试里 source/target）
          // 打开同一 in-memory 路径会共享同一个库。这里禁用缓存，每个实例独立。
          singleInstance: false,
          onConfigure: _onConfigure,
          onCreate: _onCreate,
          onUpgrade: _onUpgrade,
        ),
      );
      _db = opened;
      return opened;
    } finally {
      // 成功时 _db 已就位走快路径；失败时清空以便下次重试。
      _opening = null;
    }
  }

  /// 关闭连接并清空单例缓存（等待在途打开完成，避免关完又被其写回 _db）。
  Future<void> close() async {
    final pending = _opening;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        // 在途打开失败：无需再关，继续清理状态。
      }
    }
    final current = _db;
    _db = null;
    _opening = null;
    await current?.close();
  }

  Future<void> _onConfigure(Database db) async {
    // 必须开启外键，否则 ON DELETE CASCADE / SET NULL 不生效。
    await db.execute('PRAGMA foreign_keys = ON');
  }

  Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();
    for (final ddl in createTableStatements) {
      batch.execute(ddl);
    }
    for (final ddl in createIndexStatements) {
      batch.execute(ddl);
    }
    await batch.commit(noResult: true);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // 增量迁移，保留用户数据。每版做幂等容错（列/表已存在时跳过），
    // 便于重复升级或部分升级失败的场景重试。
    if (oldVersion < 2) {
      // V2：task 表补 start_date（yyyy-MM-dd，可空）；新增每日打卡记录表。
      if (!await _hasColumn(db, DbTables.task, 'start_date')) {
        await db.execute(
          'ALTER TABLE ${DbTables.task} ADD COLUMN start_date TEXT',
        );
      }
      await db.execute(
        createTaskDailyLogTable.replaceFirst(
          'CREATE TABLE',
          'CREATE TABLE IF NOT EXISTS',
        ),
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_task_daily_log_task '
        'ON ${DbTables.taskDailyLog}(task_id)',
      );
    }
    if (oldVersion < 3) {
      // V3：新增 AI 会话表与消息表（幂等 IF NOT EXISTS + 索引）。
      await db.execute(
        createChatSessionTable.replaceFirst(
          'CREATE TABLE',
          'CREATE TABLE IF NOT EXISTS',
        ),
      );
      await db.execute(
        createChatMessageTable.replaceFirst(
          'CREATE TABLE',
          'CREATE TABLE IF NOT EXISTS',
        ),
      );
      await db.execute(createChatMessageSessionIndex);
    }
    if (oldVersion < 4) {
      // V4：task 表补 daily_remind_time（'HH:mm' 可空，每日打卡每日提醒时刻）。
      // 先判表存在（最小夹具库可能没有 task 表），再判列，保证幂等不报错。
      if (await _hasTable(db, DbTables.task) &&
          !await _hasColumn(db, DbTables.task, 'daily_remind_time')) {
        await db.execute(
          'ALTER TABLE ${DbTables.task} ADD COLUMN daily_remind_time TEXT',
        );
      }
    }
    if (oldVersion < 5) {
      // V5：task 表补 reminder_repeat（'daily'/'once'，可空）与 remind_once_at
      // （ISO8601，可空，「不重复」的触发时刻）。老数据两列均为 null，调度侧
      // 按 daily_remind_time 兜底为每日重复，语义不变。
      if (await _hasTable(db, DbTables.task)) {
        if (!await _hasColumn(db, DbTables.task, 'reminder_repeat')) {
          await db.execute(
            'ALTER TABLE ${DbTables.task} ADD COLUMN reminder_repeat TEXT',
          );
        }
        if (!await _hasColumn(db, DbTables.task, 'remind_once_at')) {
          await db.execute(
            'ALTER TABLE ${DbTables.task} ADD COLUMN remind_once_at TEXT',
          );
        }
      }
    }
    if (oldVersion < 7 &&
        await _hasTable(db, DbTables.task) &&
        !await _hasColumn(db, DbTables.task, 'image_paths')) {
      await db.execute(
        "ALTER TABLE ${DbTables.task} ADD COLUMN image_paths TEXT NOT NULL DEFAULT '[]'",
      );
    }
    if (oldVersion < 6) {
      await db.execute(createChatQueueTable);
      await db.execute(createChatQueueSessionIndex);
      await db.execute(createChatQueueActiveIndex);
    }
    if (oldVersion < 8 && await _hasTable(db, DbTables.task)) {
      await _makeTaskDeadlineNullable(db);
    }
  }

  /// onUpgrade 本身在事务内：先保存并移走子表，再重建父表，避免 DROP
  /// task 的 ON DELETE CASCADE 清空打卡记录。任一步失败整次升级回滚。
  Future<void> _makeTaskDeadlineNullable(Database db) async {
    final columns = await db.rawQuery('PRAGMA table_info(task)');
    if (columns.singleWhere((c) => c['name'] == 'due_date')['notnull'] == 0) {
      return;
    }
    final sequences = await db.query(
      'sqlite_sequence',
      where: 'name IN (?, ?)',
      whereArgs: [DbTables.task, DbTables.taskDailyLog],
    );
    final hasLogs = await _hasTable(db, DbTables.taskDailyLog);
    if (hasLogs) {
      await db.execute(
        'CREATE TEMP TABLE task_daily_logs_v8_backup AS SELECT * FROM task_daily_logs',
      );
      await db.execute('DROP TABLE task_daily_logs');
    }
    await db.execute(
      createTaskTable.replaceFirst('CREATE TABLE task', 'CREATE TABLE task_v8'),
    );
    final names = columns.map((c) => '"${c['name']}"').join(', ');
    await db.execute('INSERT INTO task_v8 ($names) SELECT $names FROM task');
    await db.execute('DROP TABLE task');
    await db.execute('ALTER TABLE task_v8 RENAME TO task');
    await db.execute(createTaskDailyLogTable);
    if (hasLogs) {
      await db.execute(
        'INSERT INTO task_daily_logs SELECT * FROM task_daily_logs_v8_backup',
      );
      await db.execute('DROP TABLE task_daily_logs_v8_backup');
    }
    // 包括已删除最大 ID 的序列高水位，不能只依赖现存行的 MAX(id)。
    for (final sequence in sequences) {
      await db.delete(
        'sqlite_sequence',
        where: 'name = ?',
        whereArgs: [sequence['name']],
      );
      await db.insert('sqlite_sequence', sequence);
    }
    for (final ddl in createIndexStatements) {
      if (ddl.startsWith('CREATE INDEX idx_task_')) await db.execute(ddl);
    }
    if ((await db.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
      throw StateError('V8 迁移后的任务外键校验失败');
    }
  }

  /// 某表是否已含某列（迁移幂等判断用）。
  Future<bool> _hasColumn(Database db, String table, String column) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return rows.any((r) => r['name'] == column);
  }

  /// 表是否存在（迁移守卫：某些最小夹具库没有目标表）。
  Future<bool> _hasTable(Database db, String table) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [table],
    );
    return rows.isNotEmpty;
  }
}
