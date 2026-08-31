import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 建一个独立的 in-memory 测试数据库（含完整 schema），不触碰生产单例。
Future<AppDatabase> createTestDatabase() async {
  sqfliteFfiInit();
  final db = AppDatabase(
    factory: databaseFactoryFfi,
    path: inMemoryDatabasePath,
  );
  await db.database; // 触发 onCreate 迁移
  return db;
}

/// 数据层测试夹具：in-memory 库 + 三个 Repository。
class TestData {
  TestData(this.db, this.timetable, this.tasks, this.settings);

  final AppDatabase db;
  final ITimetableRepository timetable;
  final ITaskRepository tasks;
  final ISettingsRepository settings;

  static Future<TestData> create() async {
    final db = await createTestDatabase();
    return TestData(
      db,
      TimetableRepository(db),
      TaskRepository(db),
      SettingsRepository(db),
    );
  }
}
