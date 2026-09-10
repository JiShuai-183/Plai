import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/db/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  AppDatabase newDb() => AppDatabase(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );

  test('并发首次取库只打开一次：所有调用者共享同一连接', () async {
    final db = newDb();
    // 首启时 timetable/schedule/ai/theme 等 provider 会同时首次取库。
    final results = await Future.wait(
      List<Future<Database>>.generate(8, (_) => db.database),
    );
    for (final r in results) {
      expect(identical(r, results.first), isTrue,
          reason: '并发取库应共享同一次 openDatabase，而非各开一次');
    }
    await db.close();
  });

  test('关闭后再次取库会重新打开连接', () async {
    final db = newDb();
    final first = await db.database;
    await db.close();
    final second = await db.database;
    expect(identical(first, second), isFalse);
    expect(second.isOpen, isTrue);
    await db.close();
  });
}
