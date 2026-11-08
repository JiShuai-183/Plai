import 'dart:convert';

import 'date_utils.dart';

/// 任务类型（PRD-日程模块 §5 task.type）。
///
/// - [scheduled] 定时日程 / [todo] 待办任务：无起止区间，`startDate` 为空。
/// - [daily] 每日打卡：区间内每天一个实例、按天单独勾选完成。
/// - [span] 一次性跨期：勾一次即整体完成。
enum TaskType {
  scheduled('scheduled', '定时日程'),
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

/// 提醒重复方式（PRD-日程模块 §10 提醒：每天 / 不重复）。
///
/// - [daily]：每天同一时刻重复（复用 [Task.dailyRemindTime] 存 `HH:mm`）；
/// - [once]：只在 [Task.remindOnceAt] 指定的那一刻响一次。
///
/// `Task.reminderRepeat == null` 表示「未设置」（历史数据）：调度侧按
/// [Task.dailyRemindTime] 是否存在兜底为每日重复，保持老数据语义不变。
enum ReminderRepeat {
  daily('daily', '每天'),
  once('once', '不重复');

  const ReminderRepeat(this.code, this.label);

  /// 存储 / 交换用的代码。
  final String code;

  /// 中文展示名。
  final String label;

  /// 宽松解析：未知/空值返回 null（老数据与手改文件都不该炸）。
  static ReminderRepeat? tryFromCode(String? code) {
    if (code == null || code.isEmpty) return null;
    for (final ReminderRepeat v in values) {
      if (v.code == code) return v;
    }
    return null;
  }
}

/// 任务 / 日程（PRD-日程模块 §5）。
class Task {
  static const Object _unset = Object();

  Task({
    this.id,
    required this.title,
    this.description = '',
    List<String> imagePaths = const [],
    required this.type,
    this.dueDate,
    this.dueTime,
    this.dailyRemindTime,
    this.reminderRepeat,
    this.remindOnceAt,
    this.priority = Priority.normal,
    this.courseId,
    this.remindOffsetMin,
    this.remindDate,
    this.completed = false,
    this.completedAt,
    this.startDate,
    DateTime? createdAt,
  }) : imagePaths = List<String>.unmodifiable(_paths(imagePaths)),
       createdAt = createdAt ?? DateTime.now();

  /// 主键，新建时为 null。
  final int? id;

  /// 标题。
  final String title;

  /// 描述。
  final String description;

  /// App 私有目录中的照片路径。
  final List<String> imagePaths;

  /// 类型：定时日程 / 待办任务 / 每日打卡 / 一次性跨期。
  final TaskType type;

  /// 截止日期；todo 为空表示无期限，daily 为空表示长期。
  /// span/scheduled 的必填校验由业务层执行。
  final DateTime? dueDate;

  /// 起始日期（仅日期语义，`yyyy-MM-dd`）；daily/span 起止区间用，
  /// scheduled/todo 为空。
  final DateTime? startDate;

  /// 截止时刻（`HH:mm`）；定时日程必填，待办任务可空。
  final String? dueTime;

  /// 每日打卡提醒时刻（`HH:mm`，可空 = 不提醒）；daily 类型用，
  /// 每天同一时刻触发一条重复提醒（其余类型无 UI，恒为 null）。
  ///
  /// 自 V5 起，非 daily 类型选「每天」重复时也复用本字段存 `HH:mm`，
  /// 是否重复看 [reminderRepeat]。
  final String? dailyRemindTime;

  /// 提醒重复方式；null = 未设置（历史数据，调度侧按 [dailyRemindTime] 兜底）。
  final ReminderRepeat? reminderRepeat;

  /// 「不重复」提醒的触发时刻（精确到分钟）；仅 [reminderRepeat] == [ReminderRepeat.once]
  /// 时有效。存储为 ISO8601 本地时间字符串。
  final DateTime? remindOnceAt;

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
    List<String>? imagePaths,
    TaskType? type,
    Object? dueDate = _unset,
    String? dueTime,
    String? dailyRemindTime,
    ReminderRepeat? reminderRepeat,
    DateTime? remindOnceAt,
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
      imagePaths: imagePaths ?? this.imagePaths,
      type: type ?? this.type,
      dueDate: identical(dueDate, _unset) ? this.dueDate : dueDate as DateTime?,
      dueTime: dueTime ?? this.dueTime,
      dailyRemindTime: dailyRemindTime ?? this.dailyRemindTime,
      reminderRepeat: reminderRepeat ?? this.reminderRepeat,
      remindOnceAt: remindOnceAt ?? this.remindOnceAt,
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
    'image_paths': jsonEncode(imagePaths),
    'type': type.code,
    'due_date': dueDate == null ? null : dateOnlyToString(dueDate!),
    'due_time': dueTime,
    'daily_remind_time': dailyRemindTime,
    'reminder_repeat': reminderRepeat?.code,
    'remind_once_at': remindOnceAt?.toIso8601String(),
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
    imagePaths: _paths(
      map['image_paths'] == null
          ? null
          : jsonDecode(map['image_paths'] as String),
    ),
    type: TaskType.fromCode(map['type'] as String),
    dueDate: map['due_date'] == null
        ? null
        : stringToDateOnly(map['due_date'] as String),
    dueTime: map['due_time'] as String?,
    dailyRemindTime: map['daily_remind_time'] as String?,
    reminderRepeat: ReminderRepeat.tryFromCode(
      map['reminder_repeat'] as String?,
    ),
    remindOnceAt: _parseIso(map['remind_once_at'] as String?),
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
    'imagePaths': imagePaths,
    'type': type.code,
    'dueDate': dueDate == null ? null : dateOnlyToString(dueDate!),
    'dueTime': dueTime,
    'dailyRemindTime': dailyRemindTime,
    'reminderRepeat': reminderRepeat?.code,
    'remindOnceAt': remindOnceAt?.toIso8601String(),
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
    imagePaths: _paths(json['imagePaths']),
    type: TaskType.fromCode(json['type'] as String),
    dueDate: json['dueDate'] == null
        ? null
        : stringToDateOnly(json['dueDate'] as String),
    dueTime: json['dueTime'] as String?,
    dailyRemindTime: json['dailyRemindTime'] as String?,
    reminderRepeat: ReminderRepeat.tryFromCode(
      json['reminderRepeat'] as String?,
    ),
    remindOnceAt: _parseIso(json['remindOnceAt'] as String?),
    priority: Priority.fromCode(json['priority'] as String),
    courseId: json['courseId'] as int?,
    remindOffsetMin: json['remindOffsetMin'] as int?,
    remindDate: _parseIso(json['remindDate'] as String?),
    completed: (json['completed'] as bool?) ?? false,
    completedAt: _parseIso(json['completedAt'] as String?),
    startDate: tryParseDateOnly(json['startDate'] as String?),
    createdAt: _parseIso(json['createdAt'] as String?) ?? DateTime.now(),
  );

  static List<String> _paths(Object? value) {
    if (value == null) return const [];
    if (value is! List ||
        value.length > 4 ||
        value.any((p) => p is! String || p.isEmpty)) {
      throw const FormatException('任务图片必须为最多四项的路径数组');
    }
    return value.cast<String>();
  }

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
        _samePaths(other.imagePaths, imagePaths) &&
        other.type == type &&
        other.dueDate == dueDate &&
        other.dueTime == dueTime &&
        other.dailyRemindTime == dailyRemindTime &&
        other.reminderRepeat == reminderRepeat &&
        other.remindOnceAt == remindOnceAt &&
        other.priority == priority &&
        other.courseId == courseId &&
        other.remindOffsetMin == remindOffsetMin &&
        other.remindDate == remindDate &&
        other.completed == completed &&
        other.completedAt == completedAt &&
        other.startDate == startDate &&
        other.createdAt == createdAt;
  }

  static bool _samePaths(List<String> a, List<String> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);

  @override
  int get hashCode => Object.hash(
    id,
    title,
    description,
    Object.hashAll(imagePaths),
    type,
    dueDate,
    dueTime,
    dailyRemindTime,
    reminderRepeat,
    remindOnceAt,
    priority,
    courseId,
    remindOffsetMin,
    remindDate,
    completed,
    completedAt,
    startDate,
    createdAt,
  );

  @override
  String toString() =>
      'Task(id: $id, title: $title, type: $type, '
      'dueDate: ${dueDate == null ? null : dateOnlyToString(dueDate!)})';
}
