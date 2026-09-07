import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'db_schema.dart';

/// 当前数据库版本。V1 = 1；V2 = 2（task 补 start_date、新增 task_daily_logs）；
/// V3 = 3（新增 chat_session / chat_message，AI 对话历史）；
/// V4 = 4（task 补 daily_remind_time，每日打卡每日提醒时刻）。
/// 此后每加表/改表递增并补充 onUpgrade 迁移。
const int dbVersion = 4;

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

  /// 获取数据库连接（懒加载：首次调用时建库并跑迁移）。
  Future<Database> get database async {
    final current = _db;
    if (current != null && current.isOpen) return current;
    final factoryToUse = factory ?? databaseFactory;
    final pathToUse = path ?? p.join(await getDatabasesPath(), 'plai.db');
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
  }

  /// 关闭连接并清空单例缓存。
  Future<void> close() async {
    final current = _db;
    _db = null;
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
            'ALTER TABLE ${DbTables.task} ADD COLUMN start_date TEXT');
      }
      await db.execute(createTaskDailyLogTable.replaceFirst(
          'CREATE TABLE', 'CREATE TABLE IF NOT EXISTS'));
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_task_daily_log_task '
          'ON ${DbTables.taskDailyLog}(task_id)');
    }
    if (oldVersion < 3) {
      // V3：新增 AI 会话表与消息表（幂等 IF NOT EXISTS + 索引）。
      await db.execute(createChatSessionTable.replaceFirst(
          'CREATE TABLE', 'CREATE TABLE IF NOT EXISTS'));
      await db.execute(createChatMessageTable.replaceFirst(
          'CREATE TABLE', 'CREATE TABLE IF NOT EXISTS'));
      await db.execute(createChatMessageSessionIndex);
    }
    if (oldVersion < 4) {
      // V4：task 表补 daily_remind_time（'HH:mm' 可空，每日打卡每日提醒时刻）。
      // 先判表存在（最小夹具库可能没有 task 表），再判列，保证幂等不报错。
      if (await _hasTable(db, DbTables.task) &&
          !await _hasColumn(db, DbTables.task, 'daily_remind_time')) {
        await db.execute(
            'ALTER TABLE ${DbTables.task} ADD COLUMN daily_remind_time TEXT');
      }
    }
    // if (oldVersion < 5) { ... V5 新增 point_log / ai_config 表 }
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
        [table]);
    return rows.isNotEmpty;
  }
}
