import 'dart:convert';

enum ChatQueueStatus {
  queued,
  running,
  waitingConfirmation,
  failed,
  interrupted,
  completed,
  cancelled,
}

/// 入队时冻结的请求；checkpoint 是 JSON 值的深层只读快照。
class ChatQueueEntry {
  ChatQueueEntry({
    required this.id,
    required this.sessionId,
    required this.userMessageId,
    required this.text,
    List<String> imagePaths = const [],
    this.includeAppState = false,
    this.status = ChatQueueStatus.queued,
    this.error,
    Map<String, dynamic> checkpoint = const {},
    required this.createdAt,
  }) : imagePaths = List.unmodifiable(imagePaths),
       checkpoint = _freeze(checkpoint) as Map<String, dynamic>;

  final int id;
  final int sessionId;
  final int userMessageId;
  final String text;
  final List<String> imagePaths;
  final bool includeAppState;
  final ChatQueueStatus status;
  final String? error;
  final Map<String, dynamic> checkpoint;
  final DateTime createdAt;

  factory ChatQueueEntry.fromDbMap(Map<String, Object?> map) => ChatQueueEntry(
    id: map['id'] as int,
    sessionId: map['session_id'] as int,
    userMessageId: map['user_message_id'] as int,
    text: map['text'] as String,
    imagePaths: (jsonDecode(map['image_paths'] as String) as List)
        .cast<String>(),
    includeAppState: map['include_app_state'] == 1,
    status: ChatQueueStatus.values.byName(map['status'] as String),
    error: map['error'] as String?,
    checkpoint: (jsonDecode(map['checkpoint'] as String) as Map)
        .cast<String, dynamic>(),
    createdAt: DateTime.parse(map['created_at'] as String),
  );

  static dynamic _freeze(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.unmodifiable(
        value.map(
          (key, dynamic item) => MapEntry(key as String, _freeze(item)),
        ),
      );
    }
    if (value is List) return List<dynamic>.unmodifiable(value.map(_freeze));
    if (value == null || value is String || value is bool || value is num) {
      return value;
    }
    throw ArgumentError('checkpoint 仅支持 JSON 值');
  }
}
