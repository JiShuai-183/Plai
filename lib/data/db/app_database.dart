import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'db_schema.dart';

/// 当前数据库版本。V1 = 1；V2 起每加表/改表递增并补充 onUpgrade 迁移。
const int dbVersion = 1;

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
    // 增量迁移，保留用户数据。
    // if (oldVersion < 2) { ... V2 新增 point_log / ai_config / chat 表 }
    // if (oldVersion < 3) { ... }
  }
}
