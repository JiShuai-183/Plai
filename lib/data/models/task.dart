import 'date_utils.dart';

/// 任务类型（PRD-日程模块 §5 task.type）。
///
/// - [scheduled] 定点日程 / [todo] 待办任务：无起止区间，`startDate` 为空。
/// - [daily] 每日打卡：区间内每天一个实例、按天单独勾选完成。
/// - [span] 一次性跨期：勾一次即整体完成。
enum TaskType {
  scheduled('scheduled', '定点日程'),
  todo('todo', '待办任务'),
  daily('daily', '每日打卡'),
  span('span', '一次性跨期');

  const TaskType(this.code, this.label);

  /// 存储 / 交换用的代码。
  final String code;

  /// 中文展示名。
  final String label;

  static TaskType fromCode(String code) => TaskType.values.firstWhere(
        (t) => t.code == code,
        orElse: () => throw FormatException('未知任务类型: "$code"'),
      );
}

/// 优先级（PRD-日程模块 §5 task.priority）。
enum Priority {
  normal('normal', '普通'),
  important('important', '重要'),
  urgent('urgent', '紧急');

  const Priority(this.code, this.label);

  /// 存储 / 交换用的代码。
  final String code;

  /// 中文展示名。
  final String label;

  static Priority fromCode(String code) => Priority.values.firstWhere(
        (p) => p.code == code,
        orElse: () => throw FormatException('未知优先级: "$code"'),
      );
}

/// 任务 / 日程（PRD-日程模块 §5）。
class Task {
  Task({
    this.id,
    required this.title,
    this.description = '',
    required this.type,
    required this.dueDate,
    this.dueTime,
    this.priority = Priority.normal,
    this.courseId,
    this.remindOffsetMin,
    this.remindDate,
    this.completed = false,
    this.completedAt,
    this.startDate,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// 主键，新建时为 null。
  final int? id;

  /// 标题。
  final String title;

  /// 描述。
  final String description;

  /// 类型：定点日程 / 待办任务 / 每日打卡 / 一次性跨期。
  final TaskType type;

  /// 截止日期。
  final DateTime dueDate;

  /// 起始日期（仅日期语义，`yyyy-MM-dd`）；daily/span 起止区间用，
  /// scheduled/todo 为空。
  final DateTime? startDate;

  /// 截止时刻（`HH:mm`）；定点日程必填，待办任务可空。
  final String? dueTime;

  /// 优先级。
  final Priority priority;

  /// 可选关联课程 id。
  final int? courseId;

  /// 提醒偏移（分钟）：`-1` 表示准时，`null` 表示不提醒。
  final int? remindOffsetMin;

  /// 提醒触发日期时间（由上层计算后冗余存储，便于调度）。
  final DateTime? remindDate;

  /// 是否完成。
  final bool completed;

  /// 完成时间，可空。
  final DateTime? completedAt;

  /// 创建时间。
  final DateTime createdAt;

  Task copyWith({
    int? id,
    String? title,
    String? description,
    TaskType? type,
    DateTime? dueDate,
    String? dueTime,
    Priority? priority,
    int? courseId,
    int? remindOffsetMin,
    DateTime? remindDate,
    bool? completed,
    DateTime? completedAt,
    DateTime? startDate,
    DateTime? createdAt,
  }) {
    return Task(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      type: type ?? this.type,
      dueDate: dueDate ?? this.dueDate,
      dueTime: dueTime ?? this.dueTime,
      priority: priority ?? this.priority,
      courseId: courseId ?? this.courseId,
      remindOffsetMin: remindOffsetMin ?? this.remindOffsetMin,
      remindDate: remindDate ?? this.remindDate,
      completed: completed ?? this.completed,
      completedAt: completedAt ?? this.completedAt,
      startDate: startDate ?? this.startDate,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  /// 数据库行映射（completed 存 0/1）。
  Map<String, Object?> toDbMap() => {
        'id': id,
        'title': title,
        'description': description,
        'type': type.code,
        'due_date': dateOnlyToString(dueDate),
        'due_time': dueTime,
        'priority': priority.code,
        'course_id': courseId,
        'remind_offset_min': remindOffsetMin,
        'remind_date': remindDate?.toIso8601String(),
        'completed': completed ? 1 : 0,
        'completed_at': completedAt?.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
        'start_date': startDate == null ? null : dateOnlyToString(startDate!),
      };

  factory Task.fromDbMap(Map<String, Object?> map) => Task(
        id: map['id'] as int?,
        title: map['title'] as String,
        description: (map['description'] as String?) ?? '',
        type: TaskType.fromCode(map['type'] as String),
        dueDate: stringToDateOnly(map['due_date'] as String),
        dueTime: map['due_time'] as String?,
        priority: Priority.fromCode(map['priority'] as String),
        courseId: map['course_id'] as int?,
        remindOffsetMin: map['remind_offset_min'] as int?,
        remindDate: _parseIso(map['remind_date'] as String?),
        completed: (map['completed'] as int) == 1,
        completedAt: _parseIso(map['completed_at'] as String?),
        startDate: tryParseDateOnly(map['start_date'] as String?),
        createdAt: _parseIso(map['created_at'] as String) ?? DateTime.now(),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'type': type.code,
        'dueDate': dateOnlyToString(dueDate),
        'dueTime': dueTime,
        'priority': priority.code,
        'courseId': courseId,
        'remindOffsetMin': remindOffsetMin,
        'remindDate': remindDate?.toIso8601String(),
        'completed': completed,
        'completedAt': completedAt?.toIso8601String(),
        'startDate': startDate == null ? null : dateOnlyToString(startDate!),
        'createdAt': createdAt.toIso8601String(),
      };

  factory Task.fromJson(Map<String, Object?> json) => Task(
        id: json['id'] as int?,
        title: json['title'] as String,
        description: (json['description'] as String?) ?? '',
        type: TaskType.fromCode(json['type'] as String),
        dueDate: stringToDateOnly(json['dueDate'] as String),
        dueTime: json['dueTime'] as String?,
        priority: Priority.fromCode(json['priority'] as String),
        courseId: json['courseId'] as int?,
        remindOffsetMin: json['remindOffsetMin'] as int?,
        remindDate: _parseIso(json['remindDate'] as String?),
        completed: (json['completed'] as bool?) ?? false,
        completedAt: _parseIso(json['completedAt'] as String?),
        startDate: tryParseDateOnly(json['startDate'] as String?),
        createdAt: _parseIso(json['createdAt'] as String?) ?? DateTime.now(),
      );

  static DateTime? _parseIso(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Task &&
        other.id == id &&
        other.title == title &&
        other.description == description &&
        other.type == type &&
        other.dueDate == dueDate &&
        other.dueTime == dueTime &&
        other.priority == priority &&
        other.courseId == courseId &&
        other.remindOffsetMin == remindOffsetMin &&
        other.remindDate == remindDate &&
        other.completed == completed &&
        other.completedAt == completedAt &&
        other.startDate == startDate &&
        other.createdAt == createdAt;
  }

  @override
  int get hashCode => Object.hash(id, title, description, type, dueDate,
      dueTime, priority, courseId, remindOffsetMin, remindDate, completed,
      completedAt, startDate, createdAt);

  @override
  String toString() => 'Task(id: $id, title: $title, type: $type, '
      'dueDate: ${dateOnlyToString(dueDate)})';
}
