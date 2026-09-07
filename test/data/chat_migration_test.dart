import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/db/db_schema.dart';
import 'package:plai/data/models/chat_message.dart';
import 'package:plai/data/repositories/chat_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('V2 → 当前版本迁移：新增 chat 两表 + 索引，升级后可读写', () async {
    final dir = await Directory.systemTemp.createTemp('plai_chat_mig');
    final path = p.join(dir.path, 'mig.db');
    try {
      // 建一个版本 2 的旧库（V2 schema，含 setting 表即可验证迁移路径）。
      final v2 = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 2,
          singleInstance: false,
          onCreate: (db, _) async => db.execute(createSettingTable),
        ),
      );
      await v2.insert('setting', {'key': 'notify.enabled', 'value': 'true'});
      await v2.close();

      // 用 AppDatabase（当前 dbVersion）重开同一文件 → 触发 onUpgrade 2→当前。
      final migrated = AppDatabase(factory: databaseFactoryFfi, path: path);
      try {
        final db = await migrated.database;

        // 版本号升到当前，老设置保留。
        final version = await db.rawQuery('PRAGMA user_version');
        expect(version.first['user_version'], dbVersion);
        final settings = await db.query(DbTables.setting);
        expect(settings, hasLength(1));

        // chat 两表 + 消息索引已建。
        for (final table in [DbTables.chatSession, DbTables.chatMessage]) {
          final rows = await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
            [table],
          );
          expect(rows, hasLength(1), reason: '表 $table 应存在');
        }
        final indexes =
            await db.rawQuery('PRAGMA index_list(${DbTables.chatMessage})');
        expect(indexes.map((i) => i['name']),
            contains('idx_chat_message_session'));

        // 升级后可正常走 Repository 读写。
        final repo = ChatRepository(migrated);
        final sid = await repo.createSession(title: '迁移后新会话');
        await repo.appendMessage(ChatMessage(
          sessionId: sid,
          role: ChatRole.user,
          content: '迁移测试',
        ));
        expect(await repo.listSessions(), hasLength(1));
        expect((await repo.messagesFor(sid)).single.content, '迁移测试');
      } finally {
        await migrated.close();
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
