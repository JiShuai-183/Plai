import 'package:sqflite/sqflite.dart';

import '../db/app_database.dart';
import '../db/db_schema.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';

/// AI 对话域 Repository 接口：chat_session / chat_message CRUD 契约。
///
/// feature agent 只依赖本接口，实现见 [ChatRepository]。
abstract class IChatRepository {
  // ---- 会话 ChatSession ----

  /// 查询全部会话，**已排序**：置顶优先（pinned DESC）→
  /// 其余按最近活跃时间倒序（last_active_at DESC）。调用方无需再排。
  Future<List<ChatSession>> listSessions();

  /// 按 id 查询会话，不存在返回 null。
  Future<ChatSession?> getSessionById(int id);

  /// 新建会话，返回新行自增 id。title 为空串，由客户端取首条消息后
  /// 调 [renameSession] 写入；创建时 createdAt / lastActiveAt 均为当前时间。
  Future<int> createSession({String title = ''});

  /// 改会话标题，返回受影响行数（1 表示成功）。
  Future<int> renameSession(int id, String title);

  /// 置顶 / 取消置顶，返回受影响行数。
  Future<int> setPinned(int id, bool pinned);

  /// 触碰会话：把最近活跃时间更新为当前时间（新消息后应调用，驱动列表排序）。
  Future<int> touchSession(int id);

  /// 删除会话，返回受影响行数（其下全部消息随之级联删除）。
  Future<int> deleteSession(int id);

  // ---- 消息 ChatMessage ----

  /// 查询某会话全部消息，按插入序（id 升序）返回，供对话渲染与回放。
  Future<List<ChatMessage>> messagesFor(int sessionId);

  /// 追加一条消息，返回新行自增 id。
  /// 注意：本方法不自动 touch 会话；客户端如需会话在列表中前移，
  /// 追加后应自行调 [touchSession]。
  Future<int> appendMessage(ChatMessage message);

  /// 仅更新某条消息的 content（LLM 流式增量落库用），返回受影响行数。
  Future<int> updateMessageContent(int id, String content);
}

/// AI 对话域 Repository 的 sqflite 实现。
class ChatRepository implements IChatRepository {
  ChatRepository(this._db);

  final AppDatabase _db;

  Future<Database> get _database => _db.database;

  // ---- ChatSession ----

  @override
  Future<List<ChatSession>> listSessions() async {
    final db = await _database;
    final rows = await db.query(
      DbTables.chatSession,
      orderBy: 'pinned DESC, last_active_at DESC',
    );
    return rows.map(ChatSession.fromDbMap).toList();
  }

  @override
  Future<ChatSession?> getSessionById(int id) async {
    final db = await _database;
    final rows = await db.query(
      DbTables.chatSession,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : ChatSession.fromDbMap(rows.first);
  }

  @override
  Future<int> createSession({String title = ''}) async {
    final db = await _database;
    final now = DateTime.now();
    return db.insert(DbTables.chatSession, {
      'title': title,
      'created_at': now.toIso8601String(),
      'last_active_at': now.toIso8601String(),
      'pinned': 0,
    });
  }

  @override
  Future<int> renameSession(int id, String title) async {
    final db = await _database;
    return db.update(
      DbTables.chatSession,
      {'title': title},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<int> setPinned(int id, bool pinned) async {
    final db = await _database;
    return db.update(
      DbTables.chatSession,
      {'pinned': pinned ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<int> touchSession(int id) async {
    final db = await _database;
    return db.update(
      DbTables.chatSession,
      {'last_active_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<int> deleteSession(int id) async {
    final db = await _database;
    return db.delete(DbTables.chatSession, where: 'id = ?', whereArgs: [id]);
  }

  // ---- ChatMessage ----

  @override
  Future<List<ChatMessage>> messagesFor(int sessionId) async {
    final db = await _database;
    final rows = await db.query(
      DbTables.chatMessage,
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'id ASC',
    );
    return rows.map(ChatMessage.fromDbMap).toList();
  }

  @override
  Future<int> appendMessage(ChatMessage message) async {
    final db = await _database;
    final map = message.toDbMap();
    map['created_at'] ??= DateTime.now().toIso8601String();
    return db.insert(DbTables.chatMessage, map);
  }

  @override
  Future<int> updateMessageContent(int id, String content) async {
    final db = await _database;
    return db.update(
      DbTables.chatMessage,
      {'content': content},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
