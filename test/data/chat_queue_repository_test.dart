import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/db/db_schema.dart';
import 'package:plai/data/models/chat_message.dart';
import 'package:plai/data/models/chat_queue_entry.dart';
import 'package:plai/data/repositories/chat_queue_repository.dart';
import 'package:plai/data/repositories/chat_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'test_helpers.dart';

void main() {
  late AppDatabase db;
  late ChatQueueRepository queue;
  late ChatRepository chats;
  late int session;

  setUp(() async {
    db = await createTestDatabase();
    queue = ChatQueueRepository(db);
    chats = ChatRepository(db);
    session = await chats.createSession();
  });
  tearDown(() => db.close());

  test('原子入队：立即存用户消息、冻结附件、跨会话FIFO', () async {
    final paths = ['/stable/a.png'];
    final pending = queue.enqueue(
      sessionId: session,
      text: '第一条',
      imagePaths: paths,
      includeAppState: true,
    );
    paths.clear();
    final first = await pending;
    final other = await chats.createSession();
    final second = await queue.enqueue(sessionId: other, text: '第二条');
    expect(second.id, greaterThan(first.id));
    expect((await queue.list()).map((e) => e.id), [first.id, second.id]);
    final message = (await chats.messagesFor(session)).single;
    expect(message.id, first.userMessageId);
    expect(message.attachments, ['/stable/a.png']);
    expect(message.hasContext, isTrue);
    expect(() => first.imagePaths.add('changed'), throwsUnsupportedError);
    expect(await queue.list(sessionId: other), hasLength(1));
  });

  test('入队失败全部回滚，用户消息不残留', () async {
    final sql = await db.database;
    await sql.execute(
      "CREATE TRIGGER reject_queue BEFORE INSERT ON chat_queue BEGIN SELECT RAISE(ABORT, '拒绝'); END",
    );
    await expectLater(
      queue.enqueue(sessionId: session, text: '回滚'),
      throwsA(isA<DatabaseException>()),
    );
    expect(await chats.messagesFor(session), isEmpty);
    expect(await queue.list(), isEmpty);
  });

  test('撤回/取消仅未执行项，历史不残留，可返回附件', () async {
    final item = await queue.enqueue(
      sessionId: session,
      text: '撤回',
      imagePaths: ['/a'],
    );
    expect((await queue.withdraw(item.id))!.imagePaths, ['/a']);
    expect(await chats.messagesFor(session), isEmpty);
    expect(await queue.list(), isEmpty);
    expect(await queue.cancel(item.id), isNull);
    final running = await queue.enqueue(sessionId: session, text: '已开始');
    await queue.update(running.id, status: ChatQueueStatus.running);
    expect(await queue.withdraw(running.id), isNull);
    expect(await chats.messagesFor(session), hasLength(1));
  });

  test('全局仅一执行项，checkpoint与状态原子持久化，完成不可重放', () async {
    final first = await queue.enqueue(sessionId: session, text: '第一');
    final second = await queue.enqueue(
      sessionId: await chats.createSession(),
      text: '第二',
    );
    final checkpoint = <String, dynamic>{
      'writes': [
        {'id': 'op1', 'status': 'success', 'result': 7},
      ],
    };
    await queue.update(
      first.id,
      status: ChatQueueStatus.waitingConfirmation,
      checkpoint: checkpoint,
    );
    await expectLater(
      queue.update(second.id, status: ChatQueueStatus.running),
      throwsA(isA<DatabaseException>()),
    );
    var saved = (await queue.list()).first;
    expect(saved.status, ChatQueueStatus.waitingConfirmation);
    expect(saved.checkpoint, checkpoint);
    expect(
      () => (saved.checkpoint['writes'] as List).clear(),
      throwsUnsupportedError,
    );
    expect(
      () => ((saved.checkpoint['writes'] as List).first as Map)['result'] = 9,
      throwsUnsupportedError,
    );
    await queue.update(first.id, status: ChatQueueStatus.completed);
    expect(await queue.update(first.id, status: ChatQueueStatus.queued), 0);
    saved = (await queue.list()).first;
    expect(saved.status, ChatQueueStatus.completed);
    expect(saved.checkpoint, checkpoint);
  });

  test('启动恢复仅中断运行/确认，queued保持，失败错误可清理', () async {
    final first = await queue.enqueue(sessionId: session, text: '运行');
    final second = await queue.enqueue(sessionId: session, text: '排队');
    await queue.update(
      first.id,
      status: ChatQueueStatus.running,
      checkpoint: {
        'done': [1],
      },
    );
    expect(await queue.recoverInterrupted(), 1);
    expect(await queue.recoverInterrupted(), 0);
    final items = await queue.list();
    expect(items.first.status, ChatQueueStatus.interrupted);
    expect(items.first.checkpoint, {
      'done': [1],
    });
    expect(items.last.status, ChatQueueStatus.queued);
    await queue.update(second.id, status: ChatQueueStatus.waitingConfirmation);
    expect(await queue.recoverInterrupted(), 1);
    await queue.update(first.id, status: ChatQueueStatus.failed, error: '断网');
    expect((await queue.list()).first.error, '断网');
    await queue.update(
      first.id,
      status: ChatQueueStatus.queued,
      clearError: true,
    );
    expect((await queue.list()).first.error, isNull);
  });

  test('批量删除会话事务级联消息队列，返回去重附件', () async {
    final other = await chats.createSession();
    await queue.enqueue(sessionId: session, text: '甲', imagePaths: ['/a']);
    await queue.enqueue(sessionId: other, text: '乙', imagePaths: ['/a', '/b']);
    await chats.appendMessage(
      ChatMessage(
        sessionId: session,
        role: ChatRole.assistant,
        attachments: ['/c'],
      ),
    );
    final keep = await chats.createSession();
    await queue.enqueue(sessionId: keep, text: '保留');
    expect((await queue.deleteSessions([session, other, other])).toSet(), {
      '/a',
      '/b',
      '/c',
    });
    expect(await chats.getSessionById(session), isNull);
    expect(await chats.messagesFor(session), isEmpty);
    expect(await queue.list(), hasLength(1));
    expect(await queue.deleteSessions([]), isEmpty);
  });

  test('批量删除中途失败整体回滚', () async {
    final other = await chats.createSession();
    await queue.enqueue(sessionId: session, text: '甲');
    await queue.enqueue(sessionId: other, text: '乙');
    final sql = await db.database;
    await sql.execute(
      'CREATE TRIGGER protect_session BEFORE DELETE ON chat_session WHEN old.id = $other BEGIN SELECT RAISE(ABORT, \'保护\'); END',
    );
    await expectLater(
      queue.deleteSessions([session, other]),
      throwsA(isA<DatabaseException>()),
    );
    expect(await chats.listSessions(), hasLength(2));
    expect(await queue.list(), hasLength(2));
    expect(await chats.messagesFor(session), hasLength(1));
  });

  test('会话摘要跳过tool/空assistant，空会话和图片回退', () async {
    final empty = await chats.createSession();
    final image = await chats.createSession();
    await queue.enqueue(sessionId: session, text: '用户\n问题');
    await chats.appendMessage(
      ChatMessage(sessionId: session, role: ChatRole.assistant, content: '回答'),
    );
    await chats.appendMessage(
      ChatMessage(
        sessionId: session,
        role: ChatRole.tool,
        content: '{"raw":true}',
      ),
    );
    await chats.appendMessage(
      ChatMessage(
        sessionId: session,
        role: ChatRole.assistant,
        toolRecords: [
          {'tool': 'raw'},
        ],
      ),
    );
    await queue.enqueue(sessionId: image, text: '', imagePaths: ['/a']);
    expect(await queue.sessionPreviews(), {
      session: '回答',
      empty: '',
      image: '[图片]',
    });
  });

  for (final existingQueue in [false, true]) {
    test('V5→V6迁移保留历史，队列表预存在=$existingQueue，重开可读checkpoint', () async {
      final dir = await Directory.systemTemp.createTemp('plai_queue_migration');
      final path = '${dir.path}/migration.db';
      AppDatabase? migrated;
      try {
        final old = await databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: 5,
            singleInstance: false,
            onCreate: (sql, _) async {
              await sql.execute(createChatSessionTable);
              await sql.execute(createChatMessageTable);
              if (existingQueue) await sql.execute(createChatQueueTable);
            },
          ),
        );
        await old.insert(DbTables.chatSession, {
          'id': 1,
          'title': '旧会话',
          'created_at': '2026-11-06',
          'last_active_at': '2026-11-06',
        });
        await old.close();
        migrated = AppDatabase(factory: databaseFactoryFfi, path: path);
        final repo = ChatQueueRepository(migrated);
        final entry = await repo.enqueue(sessionId: 1, text: '持久化');
        await repo.update(
          entry.id,
          status: ChatQueueStatus.running,
          checkpoint: {
            'successfulWrites': ['one'],
          },
        );
        await migrated.close();
        migrated = AppDatabase(factory: databaseFactoryFfi, path: path);
        final reopened = ChatQueueRepository(migrated);
        expect(
          (await ChatRepository(migrated).getSessionById(1))!.title,
          '旧会话',
        );
        expect((await reopened.list()).single.checkpoint, {
          'successfulWrites': ['one'],
        });
        await reopened.recoverInterrupted();
        expect(
          (await reopened.list()).single.status,
          ChatQueueStatus.interrupted,
        );
        expect(await (await migrated.database).getVersion(), 6);
      } finally {
        await migrated?.close();
        await dir.delete(recursive: true);
      }
    });
  }
}
