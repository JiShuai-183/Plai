import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/task.dart';
import '../../data/repositories/task_repository.dart';
import '../../services/ai/models/ai_tool.dart';
import '../../services/notifications/notification_providers.dart';
import '../schedule/schedule_providers.dart';

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
  _setTaskCompletedTool,
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
    },
    'required': <String>['title', 'due_date'],
  },
  validate: _validateCreateTask,
  intentKey: (Map<String, dynamic> args) =>
      'create_task|${(args['title'] as String?)?.trim() ?? ''}',
  describe: (WidgetRef ref, Map<String, dynamic> args) async =>
      _describeCreateTask(args),
  execute: _executeCreateTask,
);

/// 标记任务完成 / 恢复未完成（按 id 定位，id 来自 get_tasks 查询）。
final AiWriteTool _setTaskCompletedTool = AiWriteTool(
  name: 'set_task_completed',
  label: '标记任务状态',
  description:
      '把某条任务标记为已完成或恢复为未完成（写操作，需用户确认后执行）。'
      'task_id 必须来自 get_tasks 的返回结果，不要凭记忆编造 id。',
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

// ---------------------------------------------------------------- 实现

Future<String> _describeCreateTask(Map<String, dynamic> args) async {
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
  final String timeText = time is String && time.trim().isNotEmpty
      ? ' ${time.trim()}'
      : '';
  return '新建$typeLabel「${title.isEmpty ? '（无标题）' : title}」'
      '· ${due == null ? '日期无效' : _fmtDateCn(due)}$timeText';
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
  ref.invalidate(tasksProvider);
  ref.invalidate(taskByIdProvider(id));
  return jsonEncode(<String, dynamic>{
    'status': completed ? 'completed' : 'reopened',
    'task_id': id,
    'title': existing.title,
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
