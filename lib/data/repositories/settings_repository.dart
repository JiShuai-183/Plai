import 'package:sqflite/sqflite.dart';

import '../db/app_database.dart';
import '../db/db_schema.dart';
import '../models/setting_entry.dart';

/// 设置域 Repository 接口：键值设置读写契约。
///
/// feature agent 只依赖本接口，实现见 [SettingsRepository]。
abstract class ISettingsRepository {
  /// 读取某个设置值，不存在返回 null。
  Future<String?> getValue(String key);

  /// 写入某个设置值（不存在则插入，存在则覆盖）。
  Future<void> setValue(String key, String value);

  /// 批量写入设置（用于备份恢复等场景）。
  Future<void> setAll(Map<String, String> entries);

  /// 读取全部设置为 `{key: value}`。
  Future<Map<String, String>> getAll();

  /// 删除某个设置。
  Future<void> remove(String key);
}

/// 设置域 Repository 的 sqflite 实现。
class SettingsRepository implements ISettingsRepository {
  SettingsRepository(this._db);

  final AppDatabase _db;

  Future<Database> get _database => _db.database;

  @override
  Future<String?> getValue(String key) async {
    final db = await _database;
    final rows = await db.query(
      DbTables.setting,
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  @override
  Future<void> setValue(String key, String value) async {
    final db = await _database;
    await db.insert(
      DbTables.setting,
      SettingEntry(key: key, value: value).toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> setAll(Map<String, String> entries) async {
    final db = await _database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      entries.forEach((key, value) {
        batch.insert(
          DbTables.setting,
          SettingEntry(key: key, value: value).toDbMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      });
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<Map<String, String>> getAll() async {
    final db = await _database;
    final rows = await db.query(DbTables.setting, orderBy: 'key ASC');
    final result = <String, String>{};
    for (final row in rows) {
      result[row['key'] as String] = row['value'] as String;
    }
    return result;
  }

  @override
  Future<void> remove(String key) async {
    final db = await _database;
    await db.delete(DbTables.setting, where: 'key = ?', whereArgs: [key]);
  }
}
