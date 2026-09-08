import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/course.dart';
import '../../data/models/semester.dart';
import '../../data/models/task.dart';
import '../../data/repositories/task_repository.dart';
import '../../data/repositories/timetable_repository.dart';
import '../../services/ai/models/ai_tool.dart';
import '../../services/audio/complete_sound.dart';
import '../../services/notifications/notification_providers.dart';
import '../settings/settings_providers.dart' as settings_providers;
import '../schedule/schedule_providers.dart';
import '../timetable/timetable_providers.dart' hide settingsRepositoryProvider;

/// AI 写工具（S7）：模型经 function-calling 请求**修改**用户数据。
///
/// 与只读工具的关键差别：
/// - 不直接执行——调用先转为人类可读的确认卡片（[describe]），由用户在
///   逐条确认面板中放行后，才真正执行（[execute]）；被跳过的操作以
///   `status=skipped` 回传给模型；
/// - 受 `ai.write_enabled` 门控：开关关闭时写工具 schema 不发给模型；
/// - 执行复用 schedule 模块的 `saveTask` 等入口，保证提醒调度一致。
class AiWriteTool {
  const AiWriteTool({
    required this.name,
    required this.label,
    required this.description,
    Map<String, dynamic>? parameters,
    required this.validate,
    required this.intentKey,
    required this.describe,
    required this.execute,
    this.describeQuick,
  }) : parameters = parameters ?? const <String, dynamic>{};

  /// 函数名（wire 上模型看到的名字）。
  final String name;

  /// 中文标签。
  final String label;

  /// 给模型看的能力说明（含约束：不确定的信息应先问用户，不要猜）。
  final String description;

  /// 参数 JSON Schema。
  final Map<String, dynamic> parameters;

  /// 参数有效性校验：返回错误消息（无效）或 null（有效）。
  ///
  /// 无效调用**不弹确认窗、不执行**，直接把错误回传给模型自纠——
  /// 避免模型第一次参数没传对时让用户看到一次注定失败的确认。
  final String? Function(Map<String, dynamic> args) validate;

  /// 意图键：同一发送流程内相同意图（含参数修正后的重试）只确认一次。
  final String Function(Map<String, dynamic> args) intentKey;

  /// 同步快速描述（不读数据库）：确认面板内编辑草稿后重算文案用。
  /// 仅部分工具支持（如 create_task 参数自含）；为空则卡片不可编辑。
  final String Function(Map<String, dynamic> args)? describeQuick;

  /// 参数 → 确认卡片上的人类可读描述（一句话）。
  final Future<String> Function(WidgetRef ref, Map<String, dynamic> args)
      describe;

  /// 用户确认后执行，返回回传给模型的结果 JSON 文本。
  final Future<String> Function(WidgetRef ref, Map<String, dynamic> args)
      execute;

  /// OpenAI tools[] 数组元素。
  Map<String, dynamic> toSchema() => functionTool(
        name: name,
        description: description,
        parameters: parameters,
      );
}

/// 全部写工具。
final List<AiWriteTool> aiWriteTools = <AiWriteTool>[
  _createTaskTool,
  _updateTaskTool,
  _setTaskCompletedTool,
  _updateCourseTool,
  _createCourseTool,
];

/// 按名查找写工具；不是写工具返回 null。
AiWriteTool? findAiWriteTool(String name) {
  for (final AiWriteTool t in aiWriteTools) {
    if (t.name == name) return t;
  }
  return null;
}

// ---------------------------------------------------------------- 工具定义

/// 新建日程 / 待办 / 每日打卡 / 跨期任务。
final AiWriteTool _createTaskTool = AiWriteTool(
  name: 'create_task',
  label: '新建日程',
  description:
      '为用户新建一条日程（写操作，需用户确认后执行）。'
      'title 与 due_date 必填（yyyy-MM-dd）；type：scheduled=定点日程（建议带 '
      'due_time）/ todo=待办任务 / daily=每日打卡（区间用 start_date 到 due_date，'
      '缺省单日）/ span=一次性跨期（必须给 start_date）。'
      '用户未说清日期或标题时先询问，不要替用户猜。',
  parameters: <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'title': <String, dynamic>{'type': 'string', 'description': '标题'},
      'type': <String, dynamic>{
        'type': 'string',
        'enum': <String>['scheduled', 'todo', 'daily', 'span'],
        'description': '缺省 todo',
      },
      'due_date': <String, dynamic>{
        'type': 'string',
        'description': '截止日期，yyyy-MM-dd',
      },
      'due_time': <String, dynamic>{
        'type': 'string',
        'description': '截止时刻 HH:mm，可选（scheduled 建议）',
      },
      'start_date': <String, dynamic>{
        'type': 'string',
        'description': '起始日期 yyyy-MM-dd，仅 daily/span 需要',
      },
      'priority': <String, dynamic>{
        'type': 'string',
        'enum': <String>['normal', 'important', 'urgent'],
        'description': '缺省 normal',
      },
      'description': <String, dynamic>{
        'type': 'string',
        'description': '备注，可选',
      },
      'remind_minutes': <String, dynamic>{
        'type': 'integer',
        'description':
            '提前多少分钟提醒（如用户说提前10分钟提醒则传 10）；'
            '0=准时提醒；不传=不提醒。用户的提醒要求必须用本参数表达，'
            '不要写进 description',
      },
    },
    'required': <String>['title', 'due_date'],
  },
  validate: _validateCreateTask,
  intentKey: (Map<String, dynamic> args) =>
      'create_task|${(args['title'] as String?)?.trim() ?? ''}',
  describeQuick: _describeCreateTaskSync,
  describe: (WidgetRef ref, Map<String, dynamic> args) async =>
      _describeCreateTaskSync(args),
  execute: _executeCreateTask,
);

/// 修改已有日程/任务（部分更新：只传要改的字段，其余保持不变）。
final AiWriteTool _updateTaskTool = AiWriteTool(
  name: 'update_task',
  label: '修改日程',
  description:
      '修改用户已有的一条日程/任务（写操作，需用户确认后执行）。'
      'task_id 必填且必须来自 get_tasks 的返回结果（改前先查，不要编造 id）。'
      '只传需要修改的字段，未传字段保持不变。'
      '完成状态用 set_task_completed 改，不要用本工具。',
  parameters: <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'task_id': <String, dynamic>{'type': 'integer', 'description': '任务 id'},
      'title': <String, dynamic>{'type': 'string', 'description': '新标题'},
      'type': <String, dynamic>{
        'type': 'string',
        'enum': <String>['scheduled', 'todo', 'daily', 'span'],
      },
      'due_date': <String, dynamic>{
        'type': 'string',
        'description': '新截止日期，yyyy-MM-dd',
      },
      'due_time': <String, dynamic>{
        'type': 'string',
        'description': '新截止时刻，HH:mm',
      },
      'start_date': <String, dynamic>{
        'type': 'string',
        'description': '新起始日期，yyyy-MM-dd（daily/span 区间用）',
      },
      'priority': <String, dynamic>{
        'type': 'string',
        'enum': <String>['normal', 'important', 'urgent'],
      },
      'description': <String, dynamic>{'type': 'string', 'description': '新备注'},
      'remind_minutes': <String, dynamic>{
        'type': 'integer',
        'description': '提前提醒分钟数；0=准时提醒；不传=不改',
      },
    },
    'required': <String>['task_id'],
  },
  validate: _validateUpdateTask,
  intentKey: (Map<String, dynamic> args) =>
      'update_task|${_taskIdOf(args)}|${jsonEncode(_taskChanges(args))}',
  describe: _describeUpdateTask,
  execute: _executeUpdateTask,
);

/// 标记任务完成 / 恢复未完成（按 id 定位，id 来自 get_tasks 查询）。
final AiWriteTool _setTaskCompletedTool = AiWriteTool(
  name: 'set_task_completed',
  label: '标记任务状态',
  description:
      '把某条任务标记为已完成或恢复为未完成（写操作，需用户确认后执行）。'
      'task_id 必须来自 get_tasks 的返回结果，不要凭记忆编造 id。'
      '仅当用户明确要求改变某任务的完成状态时才调用；'
      '严禁在创建任务后顺手把它标记完成。',
  parameters: <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'task_id': <String, dynamic>{'type': 'integer', 'description': '任务 id'},
      'completed': <String, dynamic>{
        'type': 'boolean',
        'description': 'true=标记完成，false=恢复未完成',
      },
    },
    'required': <String>['task_id', 'completed'],
  },
  validate: _validateSetCompleted,
  intentKey: (Map<String, dynamic> args) =>
      'set_task_completed|${_taskIdOf(args)}|${args['completed'] == true}',
  describe: _describeSetCompleted,
  execute: _executeSetCompleted,
);

/// 修改课表里已有课程（部分更新）。
final AiWriteTool _updateCourseTool = AiWriteTool(
  name: 'update_course',
  label: '修改课程',
  description:
      '修改用户课表中已有课程的信息（写操作，需用户确认后执行）。'
      'course_id 必填且必须来自 get_courses 的返回结果（改前先查，不要编造 id）。'
      '只传需要修改的字段（名称/星期几/节次/教室/教师/周次范围/单双周），'
      '未传字段保持不变。',
  parameters: <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'course_id': <String, dynamic>{'type': 'integer', 'description': '课程 id'},
      'name': <String, dynamic>{'type': 'string', 'description': '新课程名'},
      'weekday': <String, dynamic>{
        'type': 'integer',
        'description': '新上课日，1=周一 … 7=周日',
      },
      'start_period': <String, dynamic>{
        'type': 'integer',
        'description': '新起始节次',
      },
      'end_period': <String, dynamic>{
        'type': 'integer',
        'description': '新结束节次',
      },
      'location': <String, dynamic>{'type': 'string', 'description': '新教室'},
      'teacher': <String, dynamic>{'type': 'string', 'description': '新教师'},
      'start_week': <String, dynamic>{
        'type': 'integer',
        'description': '新开始周',
      },
      'end_week': <String, dynamic>{'type': 'integer', 'description': '新结束周'},
      'week_type': <String, dynamic>{
        'type': 'string',
        'enum': <String>['every', 'odd', 'even', 'custom'],
        'description': '周次类型：每周/单周/双周/自定义',
      },
      'week_list': <String, dynamic>{
        'type': 'array',
        'items': <String, dynamic>{'type': 'integer'},
        'description': '自定义周序列（week_type=custom 时用，如 [1,3,5]）',
      },
    },
    'required': <String>['course_id'],
  },
  validate: _validateUpdateCourse,
  intentKey: (Map<String, dynamic> args) =>
      'update_course|${_courseIdOf(args)}|${jsonEncode(_courseChanges(args))}',
  describe: _describeUpdateCourse,
  execute: _executeUpdateCourse,
);

/// 新建课程进当前学期课表（S9 课表识别/对话导入共用）。
///
/// 学期不暴露给模型：execute 内取当前生效学期，无学期回 error。
final AiWriteTool _createCourseTool = AiWriteTool(
  name: 'create_course',
  label: '新建课程',
  description:
      '在用户当前学期的课表里新建一门课程（写操作，需用户确认后执行）。'
      'name/weekday/start_period/end_period 必填；weekday：1=周一 … 7=周日。'
      '周次缺省为第1周到最后，week_type：every=每周/odd=单周/even=双周/'
      'custom=自定义（配合 week_list，如 [1,3,5]）。',
  parameters: <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'name': <String, dynamic>{'type': 'string', 'description': '课程名'},
      'weekday': <String, dynamic>{
        'type': 'integer',
        'description': '1=周一 … 7=周日',
      },
      'start_period': <String, dynamic>{'type': 'integer', 'description': '起始节次'},
      'end_period': <String, dynamic>{'type': 'integer', 'description': '结束节次'},
      'location': <String, dynamic>{'type': 'string', 'description': '教室，可选'},
      'teacher': <String, dynamic>{'type': 'string', 'description': '教师，可选'},
      'start_week': <String, dynamic>{'type': 'integer', 'description': '开始周，缺省 1'},
      'end_week': <String, dynamic>{'type': 'integer', 'description': '结束周，缺省学期总周数'},
      'week_type': <String, dynamic>{
        'type': 'string',
        'enum': <String>['every', 'odd', 'even', 'custom'],
        'description': '缺省 every',
      },
      'week_list': <String, dynamic>{
        'type': 'array',
        'items': <String, dynamic>{'type': 'integer'},
        'description': '自定义周序列（week_type=custom 时）',
      },
    },
    'required': <String>['name', 'weekday', 'start_period', 'end_period'],
  },
  validate: _validateCreateCourse,
  intentKey: (Map<String, dynamic> args) => 'create_course|'
      '${(args['name'] as String?)?.trim() ?? ''}|${(args['weekday'] as num?)?.toInt()}|'
      '${(args['start_period'] as num?)?.toInt()}-${(args['end_period'] as num?)?.toInt()}',
  describeQuick: _describeCreateCourseSync,
  describe: (WidgetRef ref, Map<String, dynamic> args) async =>
      _describeCreateCourseSync(args),
  execute: _executeCreateCourse,
);

// ---------------------------------------------------------------- 实现

String _describeCreateTaskSync(Map<String, dynamic> args) {
  final String title = (args['title'] as String?)?.trim() ?? '';
  String typeLabel = TaskType.todo.label;
  final Object? typeCode = args['type'];
  if (typeCode is String) {
    try {
      typeLabel = TaskType.fromCode(typeCode).label;
    } on FormatException {
      // 保持待办任务。
    }
  }
  final DateTime? due = _parseDate(args['due_date']);
  final Object? time = args['due_time'];
  final String timeText =
      time is String && time.trim().isNotEmpty ? ' ${time.trim()}' : '';
  final Object? remind = args['remind_minutes'];
  final String remindText = remind is num
      ? ((remind.toInt() == 0) ? ' · 准时提醒' : ' · 提前${remind.toInt()}分钟提醒')
      : '';
  return '新建$typeLabel「${title.isEmpty ? '（无标题）' : title}」'
      '· ${due == null ? '日期无效' : _fmtDateCn(due)}$timeText$remindText';
}

Future<String> _executeCreateTask(
    WidgetRef ref, Map<String, dynamic> args) async {
  final String title = (args['title'] as String?)?.trim() ?? '';
  if (title.isEmpty) {
    return jsonEncode(<String, dynamic>{'status': 'error', 'error': '缺少标题'});
  }
  TaskType type = TaskType.todo;
  final Object? typeCode = args['type'];
  if (typeCode is String) {
    try {
      type = TaskType.fromCode(typeCode);
    } on FormatException {
      return jsonEncode(<String, dynamic>{
        'status': 'error',
        'error': 'type 仅支持 scheduled/todo/daily/span',
      });
    }
  }
  final DateTime? due = _parseDate(args['due_date']);
  if (due == null) {
    return jsonEncode(<String, dynamic>{
      'status': 'error',
      'error': 'due_date 缺失或格式无效（需 yyyy-MM-dd）',
    });
  }
  final DateTime? start = _parseDate(args['start_date']);
  if (type == TaskType.span && start == null) {
    return jsonEncode(<String, dynamic>{
      'status': 'error',
      'error': 'span 类型需要 start_date',
    });
  }
  final Object? time = args['due_time'];
  final String? dueTime =
      time is String && time.trim().isNotEmpty ? time.trim() : null;
  Priority priority = Priority.normal;
  final Object? p = args['priority'];
  if (p is String) {
    try {
      priority = Priority.fromCode(p);
    } on FormatException {
      // 保持普通。
    }
  }

  final Task task = Task(
    title: title,
    description: args['description'] is String
        ? args['description'] as String
        : '',
    type: type,
    dueDate: due,
    dueTime: dueTime,
    priority: priority,
    startDate: start ?? (type == TaskType.daily || type == TaskType.span
        ? due
        : null),
    // 提醒偏移：remind_minutes=0 表示准时（存 -1）；正数=提前分钟；不传不提醒。
    remindOffsetMin: args['remind_minutes'] is num
        ? (args['remind_minutes'] as num).toInt() == 0
              ? -1
              : (args['remind_minutes'] as num).toInt()
        : null,
  );
  final int? id = await saveTask(ref, task);
  if (id == null) {
    return jsonEncode(<String, dynamic>{'status': 'error', 'error': '保存失败'});
  }
  return jsonEncode(<String, dynamic>{
    'status': 'created',
    'task_id': id,
    'title': title,
  });
}

Future<String> _describeSetCompleted(
    WidgetRef ref, Map<String, dynamic> args) async {
  final int? id = _taskIdOf(args);
  final bool completed = args['completed'] == true;
  String title = '任务';
  if (id != null) {
    try {
      final Task? t = await ref.read(taskRepositoryProvider).getTaskById(id);
      if (t != null) title = '「${t.title}」';
    } catch (_) {
      // 查不到标题按默认展示。
    }
  }
  return completed ? '把$title标记为已完成' : '把$title恢复为未完成';
}

Future<String> _executeSetCompleted(
    WidgetRef ref, Map<String, dynamic> args) async {
  final int? id = _taskIdOf(args);
  if (id == null) {
    return jsonEncode(
        <String, dynamic>{'status': 'error', 'error': '缺少 task_id'});
  }
  final bool completed = args['completed'] == true;
  final ITaskRepository repo = ref.read(taskRepositoryProvider);
  final Task? existing = await repo.getTaskById(id);
  if (existing == null) {
    return jsonEncode(<String, dynamic>{
      'status': 'not_found',
      'note': '任务不存在（id=$id）',
    });
  }
  final bool markingComplete = completed && !existing.completed;
  await repo.setCompleted(id, completed);
  final Task? updated = await repo.getTaskById(id);
  if (updated != null) {
    try {
      await ref
          .read(notificationSchedulerProvider)
          .scheduleTaskReminder(updated);
    } catch (_) {
      // 提醒调度失败不影响状态保存。
    }
  }
  if (markingComplete) {
    await playCompletionSound(
      ref,
      ref.read(settings_providers.settingsRepositoryProvider),
    );
  }
  ref.invalidate(tasksProvider);
  ref.invalidate(taskByIdProvider(id));
  return jsonEncode(<String, dynamic>{
    'status': completed ? 'completed' : 'reopened',
    'task_id': id,
    'title': existing.title,
  });
}

// ---------------------------------------------------------------- update_task

/// update_task 参数中允许修改的字段（顺序稳定，供意图键序列化）。
const List<String> _taskChangeFields = <String>[
  'title', 'type', 'due_date', 'due_time', 'start_date', 'priority',
  'description', 'remind_minutes',
];

Map<String, dynamic> _taskChanges(Map<String, dynamic> args) =>
    <String, dynamic>{
      for (final String k in _taskChangeFields)
        if (args.containsKey(k)) k: args[k],
    };

String? _validateUpdateTask(Map<String, dynamic> args) {
  if (_taskIdOf(args) == null) return '缺少有效的 task_id（整数）';
  bool hasAny = false;
  if (args.containsKey('title')) {
    if ((args['title'] as String?)?.trim().isEmpty ?? true) {
      return 'title 不能为空';
    }
    hasAny = true;
  }
  if (args.containsKey('type')) {
    final Object? v = args['type'];
    if (v is! String ||
        !const <String>['scheduled', 'todo', 'daily', 'span'].contains(v)) {
      return 'type 仅支持 scheduled/todo/daily/span';
    }
    hasAny = true;
  }
  if (args.containsKey('due_date')) {
    if (_parseDate(args['due_date']) == null) {
      return 'due_date 格式无效（需 yyyy-MM-dd，不能用"明天"等相对说法）';
    }
    hasAny = true;
  }
  if (args.containsKey('start_date')) {
    if (_parseDate(args['start_date']) == null) {
      return 'start_date 格式无效（需 yyyy-MM-dd）';
    }
    hasAny = true;
  }
  if (args.containsKey('due_time')) {
    final Object? v = args['due_time'];
    if (v is! String || !RegExp(r'^\d{1,2}:\d{2}$').hasMatch(v.trim())) {
      return 'due_time 格式无效（需 HH:mm）';
    }
    hasAny = true;
  }
  if (args.containsKey('priority')) {
    final Object? v = args['priority'];
    if (v is! String ||
        !const <String>['normal', 'important', 'urgent'].contains(v)) {
      return 'priority 仅支持 normal/important/urgent';
    }
    hasAny = true;
  }
  if (args.containsKey('description')) {
    if (args['description'] is! String) return 'description 需为文本';
    hasAny = true;
  }
  if (args.containsKey('remind_minutes')) {
    final Object? v = args['remind_minutes'];
    if (v is! num || v.toInt() < 0) {
      return 'remind_minutes 需为非负整数（0=准时提醒）';
    }
    hasAny = true;
  }
  if (!hasAny) return '未指定任何要修改的字段';
  return null;
}

String _remindLabel(int? offset) {
  if (offset == null) return '不提醒';
  if (offset == -1) return '准时提醒';
  return '提前$offset分钟提醒';
}

bool _isSameDate(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

Future<String> _describeUpdateTask(
    WidgetRef ref, Map<String, dynamic> args) async {
  final int? id = _taskIdOf(args);
  if (id == null) return '修改任务';
  Task? orig;
  try {
    orig = await ref.read(taskRepositoryProvider).getTaskById(id);
  } catch (_) {
    // 查不到按未找到展示。
  }
  if (orig == null) return '修改任务 #$id（未找到该任务）';

  final List<String> parts = <String>[];
  final Object? title = args['title'];
  if (title is String && title.trim() != orig.title) {
    parts.add('标题 → 「${title.trim()}」');
  }
  if (args.containsKey('due_date')) {
    final DateTime? d = _parseDate(args['due_date']);
    if (d != null && !_isSameDate(d, orig.dueDate)) {
      parts.add('日期 → ${_fmtDateCn(d)}');
    }
  }
  if (args.containsKey('due_time')) {
    final Object? v = args['due_time'];
    final String nt = v is String ? v.trim() : '';
    if (nt != (orig.dueTime ?? '')) parts.add('时刻 → ${nt.isEmpty ? '无' : nt}');
  }
  if (args.containsKey('priority')) {
    try {
      final Priority p = Priority.fromCode(args['priority'] as String);
      if (p != orig.priority) parts.add('优先级 → ${p.label}');
    } on FormatException {
      // validate 已挡，不达。
    }
  }
  if (args.containsKey('type')) {
    try {
      final TaskType t = TaskType.fromCode(args['type'] as String);
      if (t != orig.type) parts.add('类型 → ${t.label}');
    } on FormatException {
      // validate 已挡，不达。
    }
  }
  if (args.containsKey('description') &&
      args['description'] != orig.description) {
    parts.add('更新备注');
  }
  if (args.containsKey('remind_minutes')) {
    final int r = (args['remind_minutes'] as num).toInt();
    final String nt = r == 0 ? '准时提醒' : '提前$r分钟提醒';
    if (nt != _remindLabel(orig.remindOffsetMin)) parts.add('提醒 → $nt');
  }
  if (parts.isEmpty) return '修改「${orig.title}」（内容无变化）';
  return '修改「${orig.title}」：${parts.join('；')}';
}

Future<String> _executeUpdateTask(
    WidgetRef ref, Map<String, dynamic> args) async {
  final int? id = _taskIdOf(args);
  if (id == null) {
    return jsonEncode(
        <String, dynamic>{'status': 'error', 'error': '缺少 task_id'});
  }
  final ITaskRepository repo = ref.read(taskRepositoryProvider);
  final Task? orig = await repo.getTaskById(id);
  if (orig == null) {
    return jsonEncode(<String, dynamic>{
      'status': 'not_found',
      'note': '任务不存在（id=$id）',
    });
  }

  Task t = orig;
  final Object? title = args['title'];
  if (title is String && title.trim().isNotEmpty) {
    t = t.copyWith(title: title.trim());
  }
  if (args.containsKey('type')) {
    try {
      t = t.copyWith(type: TaskType.fromCode(args['type'] as String));
    } on FormatException {
      // validate 已挡，不达。
    }
  }
  final DateTime? due = _parseDate(args['due_date']);
  if (due != null) t = t.copyWith(dueDate: due);
  if (args.containsKey('start_date')) {
    final DateTime? sd = _parseDate(args['start_date']);
    if (sd != null) t = t.copyWith(startDate: sd);
  }
  if (args.containsKey('due_time')) {
    t = t.copyWith(dueTime: (args['due_time'] as String).trim());
  }
  if (args.containsKey('priority')) {
    try {
      t = t.copyWith(priority: Priority.fromCode(args['priority'] as String));
    } on FormatException {
      // validate 已挡，不达。
    }
  }
  if (args.containsKey('description')) {
    t = t.copyWith(description: args['description'] as String);
  }
  if (args.containsKey('remind_minutes')) {
    final int r = (args['remind_minutes'] as num).toInt();
    t = t.copyWith(remindOffsetMin: r == 0 ? -1 : r);
  }

  await repo.updateTask(t);
  final Task? saved = await repo.getTaskById(id);
  if (saved != null) {
    try {
      await ref
          .read(notificationSchedulerProvider)
          .scheduleTaskReminder(saved);
    } catch (_) {
      // 提醒调度失败不影响保存。
    }
  }
  ref.invalidate(tasksProvider);
  ref.invalidate(taskByIdProvider(id));
  return jsonEncode(<String, dynamic>{
    'status': 'updated',
    'task_id': id,
    'title': t.title,
  });
}

// ------------------------------------------------------------- update_course

/// update_course 参数中允许修改的字段。
const List<String> _courseChangeFields = <String>[
  'name', 'weekday', 'start_period', 'end_period', 'location', 'teacher',
  'start_week', 'end_week', 'week_type', 'week_list',
];

Map<String, dynamic> _courseChanges(Map<String, dynamic> args) =>
    <String, dynamic>{
      for (final String k in _courseChangeFields)
        if (args.containsKey(k)) k: args[k],
    };

int? _courseIdOf(Map<String, dynamic> args) {
  final Object? v = args['course_id'];
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

String? _validateUpdateCourse(Map<String, dynamic> args) {
  if (_courseIdOf(args) == null) return '缺少有效的 course_id（整数）';
  bool hasAny = false;
  if (args.containsKey('name')) {
    if ((args['name'] as String?)?.trim().isEmpty ?? true) {
      return 'name 不能为空';
    }
    hasAny = true;
  }
  if (args.containsKey('weekday')) {
    final Object? v = args['weekday'];
    if (v is! num || v.toInt() < 1 || v.toInt() > 7) {
      return 'weekday 需为 1（周一）到 7（周日）';
    }
    hasAny = true;
  }
  if (args.containsKey('start_period') || args.containsKey('end_period')) {
    for (final String k in <String>['start_period', 'end_period']) {
      if (args.containsKey(k)) {
        final Object? v = args[k];
        if (v is! num || v.toInt() < 1) return '$k 需为正整数';
      }
    }
    hasAny = true;
  }
  if (args.containsKey('location') || args.containsKey('teacher')) {
    for (final String k in <String>['location', 'teacher']) {
      if (args.containsKey(k) && args[k] is! String) return '$k 需为文本';
    }
    hasAny = true;
  }
  if (args.containsKey('start_week') || args.containsKey('end_week')) {
    for (final String k in <String>['start_week', 'end_week']) {
      if (args.containsKey(k)) {
        final Object? v = args[k];
        if (v is! num || v.toInt() < 1) return '$k 需为正整数';
      }
    }
    hasAny = true;
  }
  if (args.containsKey('week_type')) {
    final Object? v = args['week_type'];
    if (v is! String ||
        !const <String>['every', 'odd', 'even', 'custom'].contains(v)) {
      return 'week_type 仅支持 every/odd/even/custom';
    }
    hasAny = true;
  }
  if (args.containsKey('week_list')) {
    final Object? v = args['week_list'];
    if (v is! List || v.any((Object? e) => e is! num || e < 1)) {
      return 'week_list 需为正整数数组（如 [1,3,5]）';
    }
    hasAny = true;
  }
  if (!hasAny) return '未指定任何要修改的字段';
  return null;
}

const List<String> _weekdayNames = <String>[
  '周一', '周二', '周三', '周四', '周五', '周六', '周日',
];

Future<String> _describeUpdateCourse(
    WidgetRef ref, Map<String, dynamic> args) async {
  final int? id = _courseIdOf(args);
  if (id == null) return '修改课程';
  Course? orig;
  try {
    orig = await ref.read(timetableRepositoryProvider).getCourseById(id);
  } catch (_) {
    // 查不到按未找到展示。
  }
  if (orig == null) return '修改课程 #$id（未找到该课程）';

  final List<String> parts = <String>[];
  final Object? name = args['name'];
  if (name is String && name.trim() != orig.name) {
    parts.add('名称 → 「${name.trim()}」');
  }
  if (args.containsKey('weekday')) {
    final int w = (args['weekday'] as num).toInt();
    if (w != orig.weekday) parts.add('上课日 → ${_weekdayNames[w - 1]}');
  }
  if (args.containsKey('start_period') || args.containsKey('end_period')) {
    final int sp = args.containsKey('start_period')
        ? (args['start_period'] as num).toInt()
        : orig.startPeriod;
    final int ep = args.containsKey('end_period')
        ? (args['end_period'] as num).toInt()
        : orig.endPeriod;
    if (sp != orig.startPeriod || ep != orig.endPeriod) {
      parts.add('节次 → $sp-$ep节');
    }
  }
  final Object? loc = args['location'];
  if (loc is String && loc.trim() != orig.location) {
    parts.add('教室 → ${loc.trim().isEmpty ? '（清空）' : loc.trim()}');
  }
  final Object? teacher = args['teacher'];
  if (teacher is String && teacher.trim() != orig.teacher) {
    parts.add('教师 → ${teacher.trim().isEmpty ? '（清空）' : teacher.trim()}');
  }
  if (args.containsKey('start_week') || args.containsKey('end_week')) {
    final int sw = args.containsKey('start_week')
        ? (args['start_week'] as num).toInt()
        : orig.startWeek;
    final int ew = args.containsKey('end_week')
        ? (args['end_week'] as num).toInt()
        : orig.endWeek;
    if (sw != orig.startWeek || ew != orig.endWeek) {
      parts.add('周次 → 第$sw-$ew周');
    }
  }
  if (args.containsKey('week_type')) {
    try {
      final WeekType wt = WeekType.fromCode(args['week_type'] as String);
      if (wt != orig.weekType) parts.add('周次类型 → ${wt.label}');
    } on FormatException {
      // validate 已挡，不达。
    }
  }
  if (args.containsKey('week_list')) {
    final List<int> list = <int>[
      for (final Object? e in args['week_list'] as List) (e as num).toInt(),
    ];
    parts.add('自定义周 → 第${list.join(',')}周');
  }
  if (parts.isEmpty) return '修改课程「${orig.name}」（内容无变化）';
  return '修改课程「${orig.name}」：${parts.join('；')}';
}

Future<String> _executeUpdateCourse(
    WidgetRef ref, Map<String, dynamic> args) async {
  final int? id = _courseIdOf(args);
  if (id == null) {
    return jsonEncode(
        <String, dynamic>{'status': 'error', 'error': '缺少 course_id'});
  }
  final ITimetableRepository repo = ref.read(timetableRepositoryProvider);
  final Course? orig = await repo.getCourseById(id);
  if (orig == null) {
    return jsonEncode(<String, dynamic>{
      'status': 'not_found',
      'note': '课程不存在（id=$id）',
    });
  }

  Course c = orig;
  final Object? name = args['name'];
  if (name is String && name.trim().isNotEmpty) {
    c = c.copyWith(name: name.trim());
  }
  if (args.containsKey('weekday')) {
    c = c.copyWith(weekday: (args['weekday'] as num).toInt());
  }
  if (args.containsKey('start_period')) {
    c = c.copyWith(startPeriod: (args['start_period'] as num).toInt());
  }
  if (args.containsKey('end_period')) {
    c = c.copyWith(endPeriod: (args['end_period'] as num).toInt());
  }
  if (args.containsKey('location')) {
    c = c.copyWith(location: (args['location'] as String).trim());
  }
  if (args.containsKey('teacher')) {
    c = c.copyWith(teacher: (args['teacher'] as String).trim());
  }
  if (args.containsKey('start_week')) {
    c = c.copyWith(startWeek: (args['start_week'] as num).toInt());
  }
  if (args.containsKey('end_week')) {
    c = c.copyWith(endWeek: (args['end_week'] as num).toInt());
  }
  if (args.containsKey('week_type')) {
    try {
      c = c.copyWith(weekType: WeekType.fromCode(args['week_type'] as String));
    } on FormatException {
      // validate 已挡，不达。
    }
  }
  if (args.containsKey('week_list')) {
    c = c.copyWith(weekList: <int>[
      for (final Object? e in args['week_list'] as List) (e as num).toInt(),
    ]);
  }

  await repo.updateCourse(c);
  ref.invalidate(coursesProvider);
  try {
    await rescheduleTimetableReminders(ref);
  } catch (_) {
    // 提醒重排失败不影响保存。
  }
  return jsonEncode(<String, dynamic>{
    'status': 'updated',
    'course_id': id,
    'name': c.name,
  });
}

// ------------------------------------------------------------- create_course

/// create_course 参数校验。
String? _validateCreateCourse(Map<String, dynamic> args) {
  final String name = (args['name'] as String?)?.trim() ?? '';
  if (name.isEmpty) return '缺少课程名 name';
  final Object? wd = args['weekday'];
  if (wd is! num || wd.toInt() < 1 || wd.toInt() > 7) {
    return 'weekday 需为 1（周一）到 7（周日）';
  }
  final Object? sp = args['start_period'];
  final Object? ep = args['end_period'];
  if (sp is! num || sp.toInt() < 1) return 'start_period 需为正整数';
  if (ep is! num || ep.toInt() < sp.toInt()) {
    return 'end_period 需不小于 start_period 的正整数';
  }
  if (args.containsKey('week_type')) {
    final Object? v = args['week_type'];
    if (v is! String ||
        !const <String>['every', 'odd', 'even', 'custom'].contains(v)) {
      return 'week_type 仅支持 every/odd/even/custom';
    }
  }
  if (args.containsKey('week_list')) {
    final Object? v = args['week_list'];
    if (v is! List || v.any((Object? e) => e is! num || e < 1)) {
      return 'week_list 需为正整数数组（如 [1,3,5]）';
    }
  }
  return null;
}

/// create_course 确认卡文案（纯参数，支持面板内重算）。
String _describeCreateCourseSync(Map<String, dynamic> args) {
  final String name = (args['name'] as String?)?.trim() ?? '';
  final int wd = args['weekday'] is num ? (args['weekday'] as num).toInt() : 1;
  final int sp =
      args['start_period'] is num ? (args['start_period'] as num).toInt() : 1;
  final int ep =
      args['end_period'] is num ? (args['end_period'] as num).toInt() : sp;
  final String loc = (args['location'] as String?)?.trim() ?? '';
  final int sw = args['start_week'] is num
      ? (args['start_week'] as num).toInt()
      : 1;
  final int ew = args['end_week'] is num
      ? (args['end_week'] as num).toInt()
      : 0;
  final String weekText = ew > 0
      ? (sw == ew ? '第$sw周' : '第$sw-$ew周')
      : '整学期';
  final Object? wtCode = args['week_type'];
  String weekSuffix = '';
  if (wtCode == 'odd') {
    weekSuffix = '（单周）';
  } else if (wtCode == 'even') {
    weekSuffix = '（双周）';
  }
  return '新建课程「${name.isEmpty ? '（无名）' : name}」'
      '· ${_weekdayNames[wd - 1]} $sp-$ep节 · $weekText$weekSuffix'
      '${loc.isEmpty ? '' : ' · $loc'}';
}

Future<String> _executeCreateCourse(
    WidgetRef ref, Map<String, dynamic> args) async {
  final ITimetableRepository repo = ref.read(timetableRepositoryProvider);
  final Semester? semester = await ref.read(currentSemesterProvider.future);
  if (semester == null || semester.id == null) {
    return jsonEncode(<String, dynamic>{
      'status': 'error',
      'error': '尚未设置学期，请用户先到课表页添加学期后再导入',
    });
  }
  final Course course = Course(
    semesterId: semester.id!,
    name: (args['name'] as String?)?.trim() ?? '',
    weekday: (args['weekday'] as num?)?.toInt() ?? 1,
    startPeriod: (args['start_period'] as num?)?.toInt() ?? 1,
    endPeriod: (args['end_period'] as num?)?.toInt() ?? 1,
    location: (args['location'] as String?)?.trim() ?? '',
    teacher: (args['teacher'] as String?)?.trim() ?? '',
    startWeek: args['start_week'] is num
        ? (args['start_week'] as num).toInt()
        : 1,
    endWeek: args['end_week'] is num
        ? (args['end_week'] as num).toInt()
        : semester.totalWeeks,
    weekType: args['week_type'] is String
        ? WeekType.fromCodeLenient(args['week_type'] as String)
        : WeekType.every,
    weekList: args['week_list'] is List
        ? <int>[
            for (final Object? e in args['week_list'] as List)
              if (e is num) e.toInt(),
          ]
        : const <int>[],
  );
  if (course.name.isEmpty) {
    return jsonEncode(
        <String, dynamic>{'status': 'error', 'error': '课程名为空'});
  }
  await repo.insertCourse(course);
  ref.invalidate(coursesProvider);
  try {
    await rescheduleTimetableReminders(ref);
  } catch (_) {
    // 提醒重排失败不影响保存。
  }
  return jsonEncode(<String, dynamic>{
    'status': 'created',
    'name': course.name,
    'semester': semester.name,
  });
}

// ---------------------------------------------------------------- 辅助

/// create_task 参数校验：返回错误消息或 null（有效）。
String? _validateCreateTask(Map<String, dynamic> args) {
  final String title = (args['title'] as String?)?.trim() ?? '';
  if (title.isEmpty) return '缺少标题 title';
  final Object? typeCode = args['type'];
  if (typeCode != null) {
    if (typeCode is! String ||
        !const <String>['scheduled', 'todo', 'daily', 'span']
            .contains(typeCode)) {
      return 'type 仅支持 scheduled/todo/daily/span';
    }
  }
  if (_parseDate(args['due_date']) == null) {
    return 'due_date 缺失或格式无效（需 yyyy-MM-dd，不能用"明天"等相对说法）';
  }
  final String type = typeCode is String ? typeCode : 'todo';
  if (type == 'span' && _parseDate(args['start_date']) == null) {
    return 'span 类型需要 start_date';
  }
  return null;
}

/// set_task_completed 参数校验。
String? _validateSetCompleted(Map<String, dynamic> args) {
  return _taskIdOf(args) == null ? '缺少有效的 task_id（整数）' : null;
}

/// 任务 id 解析：兼容整数与数字字符串（模型侧类型不稳定）。
int? _taskIdOf(Map<String, dynamic> args) {
  final Object? v = args['task_id'];
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

DateTime? _parseDate(Object? raw) {
  if (raw is! String) return null;
  final DateTime? parsed = DateTime.tryParse(raw.trim());
  if (parsed == null) return null;
  return DateTime(parsed.year, parsed.month, parsed.day);
}

/// 确认卡片用的中文日期：同年省略年份。
String _fmtDateCn(DateTime d) {
  final DateTime now = DateTime.now();
  final String md = '${d.month}月${d.day}日';
  return d.year == now.year ? md : '${d.year}年$md';
}
