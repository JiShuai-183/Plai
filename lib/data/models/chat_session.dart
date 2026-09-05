/// AI 对话会话（PRD §8 ChatSession）。
///
/// 只读模型：会话历史列表的标题 / 置顶 / 活跃状态。
/// 时间统一存 ISO8601（含时区），数据库里直接字符串比较即可保证倒序。
class ChatSession {
  ChatSession({
    this.id,
    this.title = '',
    DateTime? createdAt,
    DateTime? lastActiveAt,
    this.pinned = false,
  })  : createdAt = createdAt ?? DateTime.now(),
        lastActiveAt = lastActiveAt ?? DateTime.now();

  /// 主键，新建时为 null。
  final int? id;

  /// 标题。新建时为空串，客户端取首条消息内容后经 [IChatRepository.renameSession] 写入。
  final String title;

  /// 创建时间。
  final DateTime createdAt;

  /// 最近活跃时间（排序依据：置顶优先 → 其余按此倒序）。
  final DateTime lastActiveAt;

  /// 是否置顶（默认 false）。
  final bool pinned;

  ChatSession copyWith({
    int? id,
    String? title,
    DateTime? createdAt,
    DateTime? lastActiveAt,
    bool? pinned,
  }) {
    return ChatSession(
      id: id ?? this.id,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      lastActiveAt: lastActiveAt ?? this.lastActiveAt,
      pinned: pinned ?? this.pinned,
    );
  }

  /// 数据库行映射（pinned 存 0/1）。
  Map<String, Object?> toDbMap() => {
        'id': id,
        'title': title,
        'created_at': createdAt.toIso8601String(),
        'last_active_at': lastActiveAt.toIso8601String(),
        'pinned': pinned ? 1 : 0,
      };

  factory ChatSession.fromDbMap(Map<String, Object?> map) => ChatSession(
        id: map['id'] as int?,
        title: (map['title'] as String?) ?? '',
        createdAt: DateTime.tryParse(map['created_at'] as String) ??
            DateTime.now(),
        lastActiveAt: DateTime.tryParse(map['last_active_at'] as String) ??
            DateTime.now(),
        pinned: (map['pinned'] as int? ?? 0) == 1,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'lastActiveAt': lastActiveAt.toIso8601String(),
        'pinned': pinned,
      };

  factory ChatSession.fromJson(Map<String, Object?> json) => ChatSession(
        id: json['id'] as int?,
        title: (json['title'] as String?) ?? '',
        createdAt: DateTime.tryParse(json['createdAt'] as String) ??
            DateTime.now(),
        lastActiveAt: DateTime.tryParse(json['lastActiveAt'] as String) ??
            DateTime.now(),
        pinned: (json['pinned'] as bool?) ?? false,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ChatSession &&
        other.id == id &&
        other.title == title &&
        other.createdAt == createdAt &&
        other.lastActiveAt == lastActiveAt &&
        other.pinned == pinned;
  }

  @override
  int get hashCode =>
      Object.hash(id, title, createdAt, lastActiveAt, pinned);

  @override
  String toString() =>
      'ChatSession(id: $id, title: $title, pinned: $pinned, '
      'lastActiveAt: $lastActiveAt)';
}
