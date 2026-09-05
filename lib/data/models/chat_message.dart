import 'dart:convert';

/// 消息角色（PRD §8 ChatMessage.role）。
enum ChatRole {
  user('user', '用户'),
  assistant('assistant', 'AI'),
  tool('tool', '工具');

  const ChatRole(this.code, this.label);

  /// 存储 / 交换用的代码。
  final String code;

  /// 中文展示名。
  final String label;

  static ChatRole fromCode(String code) => ChatRole.values.firstWhere(
        (r) => r.code == code,
        orElse: () => throw FormatException('未知消息角色: "$code"'),
      );
}

/// AI 对话消息（PRD §8 ChatMessage）。
///
/// 只读模型，类型化访问两段 JSON 存储内容：
/// - [attachments]：`List<String>` 图片本地路径（DB 里存 JSON 数组字符串）；
/// - [toolRecords]：`List<Map<String, dynamic>>` 工具调用/结果记录
///   （DB 里存 JSON 数组字符串，供多轮工具链与回放）。
///
/// 时间统一存 ISO8601；会话内消息按插入序（id 升序）排列。
class ChatMessage {
  ChatMessage({
    this.id,
    required this.sessionId,
    required this.role,
    this.content = '',
    this.hasContext = false,
    List<String>? attachments,
    List<Map<String, dynamic>>? toolRecords,
    DateTime? createdAt,
  })  : attachments = attachments ?? const [],
        toolRecords = toolRecords ?? const [],
        createdAt = createdAt ?? DateTime.now();

  /// 主键，新建时为 null。
  final int? id;

  /// 所属会话 id。
  final int sessionId;

  /// 角色：用户 / AI / 工具。
  final ChatRole role;

  /// 文本内容（tool 角色的执行结果文本也存这里）。
  final String content;

  /// 是否附带上下文标记（如引用课程/任务/设置，默认 false）。
  final bool hasContext;

  /// 图片附件本地路径（可空）。
  final List<String> attachments;

  /// 工具调用与结果记录（可空，泛型 Map 结构，未来回放扩展不改列）。
  final List<Map<String, dynamic>> toolRecords;

  /// 记录时间。
  final DateTime createdAt;

  ChatMessage copyWith({
    int? id,
    int? sessionId,
    ChatRole? role,
    String? content,
    bool? hasContext,
    List<String>? attachments,
    List<Map<String, dynamic>>? toolRecords,
    DateTime? createdAt,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      role: role ?? this.role,
      content: content ?? this.content,
      hasContext: hasContext ?? this.hasContext,
      attachments: attachments ?? this.attachments,
      toolRecords: toolRecords ?? this.toolRecords,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  /// 数据库行映射（has_context 存 0/1；attachments/tool_data 存 JSON）。
  Map<String, Object?> toDbMap() => {
        'id': id,
        'session_id': sessionId,
        'role': role.code,
        'content': content,
        'has_context': hasContext ? 1 : 0,
        'attachments':
            attachments.isEmpty ? null : jsonEncode(attachments),
        'tool_data': toolRecords.isEmpty ? null : jsonEncode(toolRecords),
        'created_at': createdAt.toIso8601String(),
      };

  factory ChatMessage.fromDbMap(Map<String, Object?> map) => ChatMessage(
        id: map['id'] as int?,
        sessionId: map['session_id'] as int,
        role: ChatRole.fromCode(map['role'] as String),
        content: (map['content'] as String?) ?? '',
        hasContext: (map['has_context'] as int? ?? 0) == 1,
        attachments: _decodeStringList(map['attachments'] as String?),
        toolRecords: _decodeToolRecords(map['tool_data'] as String?),
        createdAt: DateTime.tryParse(map['created_at'] as String) ??
            DateTime.now(),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'sessionId': sessionId,
        'role': role.code,
        'content': content,
        'hasContext': hasContext,
        'attachments': attachments,
        'toolRecords': toolRecords,
        'createdAt': createdAt.toIso8601String(),
      };

  factory ChatMessage.fromJson(Map<String, Object?> json) => ChatMessage(
        id: json['id'] as int?,
        sessionId: json['sessionId'] as int,
        role: ChatRole.fromCode(json['role'] as String),
        content: (json['content'] as String?) ?? '',
        hasContext: (json['hasContext'] as bool?) ?? false,
        attachments: (json['attachments'] as List?)?.cast<String>() ??
            const [],
        toolRecords: (json['toolRecords'] as List?)
                ?.map((e) => (e as Map).cast<String, dynamic>())
                .toList() ??
            const [],
        createdAt: DateTime.tryParse(json['createdAt'] as String) ??
            DateTime.now(),
      );

  static List<String> _decodeStringList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } on FormatException {
      return const [];
    } on TypeError {
      return const [];
    }
  }

  static List<Map<String, dynamic>> _decodeToolRecords(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList(growable: false);
    } on FormatException {
      return const [];
    } on TypeError {
      return const [];
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ChatMessage &&
        other.id == id &&
        other.sessionId == sessionId &&
        other.role == role &&
        other.content == content &&
        other.hasContext == hasContext &&
        _listEquals(other.attachments, attachments) &&
        _listOfMapsEquals(other.toolRecords, toolRecords) &&
        other.createdAt == createdAt;
  }

  @override
  int get hashCode => Object.hash(id, sessionId, role, content, hasContext,
      Object.hashAll(attachments), _toolRecordsHash(toolRecords), createdAt);

  @override
  String toString() => 'ChatMessage(id: $id, sessionId: $sessionId, '
      'role: $role, content: "$content")';

  static bool _listEquals(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _listOfMapsEquals(
    List<Map<String, dynamic>> a,
    List<Map<String, dynamic>> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_mapEquals(a[i], b[i])) return false;
    }
    return true;
  }

  static bool _mapEquals(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (a[key] != b[key]) return false;
    }
    return true;
  }

  static int _toolRecordsHash(List<Map<String, dynamic>> records) {
    var hash = 0;
    for (final m in records) {
      for (final v in m.values) {
        hash = Object.hash(hash, v);
      }
    }
    return hash;
  }
}
