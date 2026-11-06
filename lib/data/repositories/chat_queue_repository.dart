import 'dart:convert';

import '../db/app_database.dart';
import '../db/db_schema.dart';
import '../models/chat_message.dart';
import '../models/chat_queue_entry.dart';

/// 持久队列契约。调度、手动恢复、工具执行与附件文件生命周期由 AI 服务负责。
abstract class IChatQueueRepository {
  Future<List<ChatQueueEntry>> list({int? sessionId});
  Future<ChatQueueEntry> enqueue({
    required int sessionId,
    required String text,
    List<String> imagePaths = const [],
    bool includeAppState = false,
  });
  Future<int> update(
    int id, {
    ChatQueueStatus? status,
    String? error,
    Map<String, dynamic>? checkpoint,
    bool clearError = false,
  });

  /// 仅 queued 可撤回；原子删除用户消息与队列项，返回快照供清理附件。
  Future<ChatQueueEntry?> cancel(int id);
  Future<ChatQueueEntry?> withdraw(int id);
  Future<int> recoverInterrupted();

  /// 事务删除会话/消息/队列，返回附件路径，调用方负责清理文件。
  Future<List<String>> deleteSessions(List<int> ids);

  /// 所有会话的最后可展示消息摘要，一次 JOIN 查询；空会话值为空串。
  Future<Map<int, String>> sessionPreviews();
}

class ChatQueueRepository implements IChatQueueRepository {
  ChatQueueRepository(this._db);
  final AppDatabase _db;

  @override
  Future<List<ChatQueueEntry>> list({int? sessionId}) async {
    final db = await _db.database;
    final rows = await db.query(
      DbTables.chatQueue,
      where: sessionId == null ? null : 'session_id = ?',
      whereArgs: sessionId == null ? null : [sessionId],
      orderBy: 'id ASC',
    );
    return rows.map(ChatQueueEntry.fromDbMap).toList();
  }

  @override
  Future<ChatQueueEntry> enqueue({
    required int sessionId,
    required String text,
    List<String> imagePaths = const [],
    bool includeAppState = false,
  }) async {
    // 在第一次 await 前取快照，调用方之后修改集合不影响请求。
    final paths = List<String>.unmodifiable(imagePaths);
    final encodedPaths = jsonEncode(paths);
    final now = DateTime.now();
    final db = await _db.database;
    return db.transaction((txn) async {
      final messageId = await txn.insert(
        DbTables.chatMessage,
        ChatMessage(
          sessionId: sessionId,
          role: ChatRole.user,
          content: text,
          attachments: paths,
          hasContext: includeAppState,
          createdAt: now,
        ).toDbMap(),
      );
      final id = await txn.insert(DbTables.chatQueue, {
        'session_id': sessionId,
        'user_message_id': messageId,
        'text': text,
        'image_paths': encodedPaths,
        'include_app_state': includeAppState ? 1 : 0,
        'status': ChatQueueStatus.queued.name,
        'created_at': now.toIso8601String(),
      });
      await txn.update(
        DbTables.chatSession,
        {'last_active_at': now.toIso8601String()},
        where: 'id = ?',
        whereArgs: [sessionId],
      );
      return ChatQueueEntry(
        id: id,
        sessionId: sessionId,
        userMessageId: messageId,
        text: text,
        imagePaths: paths,
        includeAppState: includeAppState,
        createdAt: now,
      );
    });
  }

  @override
  Future<int> update(
    int id, {
    ChatQueueStatus? status,
    String? error,
    Map<String, dynamic>? checkpoint,
    bool clearError = false,
  }) async {
    final values = <String, Object?>{
      if (status != null) 'status': status.name,
      if (error != null || clearError) 'error': error,
      if (checkpoint != null) 'checkpoint': jsonEncode(checkpoint),
    };
    if (values.isEmpty) return 0;
    final db = await _db.database;
    // 已完成/取消项不得再次进入执行流程；checkpoint 可继续补充。
    return db.update(
      DbTables.chatQueue,
      values,
      where: status == null
          ? 'id = ?'
          : "id = ? AND status NOT IN ('completed','cancelled')",
      whereArgs: [id],
    );
  }

  @override
  Future<ChatQueueEntry?> cancel(int id) => withdraw(id);

  @override
  Future<ChatQueueEntry?> withdraw(int id) async {
    final db = await _db.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        DbTables.chatQueue,
        where: "id = ? AND status = 'queued'",
        whereArgs: [id],
      );
      if (rows.isEmpty) return null;
      final entry = ChatQueueEntry.fromDbMap(rows.single);
      // 外键级联同时删除任务，消息不会留在未来请求上下文中。
      await txn.delete(
        DbTables.chatMessage,
        where: 'id = ?',
        whereArgs: [entry.userMessageId],
      );
      return entry;
    });
  }

  @override
  Future<int> recoverInterrupted() async {
    final db = await _db.database;
    return db.update(DbTables.chatQueue, {
      'status': ChatQueueStatus.interrupted.name,
    }, where: "status IN ('running','waitingConfirmation')");
  }

  @override
  Future<List<String>> deleteSessions(List<int> ids) async {
    final sessionIds = ids.toSet().toList();
    if (sessionIds.isEmpty) return [];
    final db = await _db.database;
    return db.transaction((txn) async {
      final paths = <String>{};
      // 分批避免 SQLite 参数上限；仍处于同一事务。
      for (var start = 0; start < sessionIds.length; start += 400) {
        final chunk = sessionIds.skip(start).take(400).toList();
        final placeholders = List.filled(chunk.length, '?').join(',');
        final rows = await txn.query(
          DbTables.chatMessage,
          columns: ['attachments'],
          where: 'session_id IN ($placeholders)',
          whereArgs: chunk,
        );
        for (final row in rows) {
          final raw = row['attachments'] as String?;
          if (raw != null && raw.isNotEmpty) {
            paths.addAll((jsonDecode(raw) as List).cast<String>());
          }
        }
        await txn.delete(
          DbTables.chatSession,
          where: 'id IN ($placeholders)',
          whereArgs: chunk,
        );
      }
      return paths.toList();
    });
  }

  @override
  Future<Map<int, String>> sessionPreviews() async {
    final db = await _db.database;
    final rows = await db.rawQuery('''
SELECT s.id AS session_id, m.content, m.attachments
FROM chat_session s LEFT JOIN chat_message m ON m.id = (
  SELECT MAX(p.id) FROM chat_message p WHERE p.session_id = s.id
  AND p.role IN ('user','assistant')
  AND (TRIM(p.content) <> '' OR (p.attachments IS NOT NULL AND p.attachments <> '[]'))
)
''');
    return {for (final row in rows) row['session_id'] as int: _preview(row)};
  }

  static String _preview(Map<String, Object?> row) {
    final text = (row['content'] as String? ?? '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isNotEmpty) {
      return text.length > 100 ? '${text.substring(0, 100)}…' : text;
    }
    final paths = row['attachments'] as String?;
    return paths == null || paths.isEmpty || paths == '[]' ? '' : '[图片]';
  }
}
