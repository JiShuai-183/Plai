import '../../data/models/task.dart';
import '../../data/models/date_utils.dart';

/// 模型按意图给出类型；旧调用未给类型时，以任务自身信息补足，不用整批原话串类型。
TaskType aiCreateTaskType(Map<String, dynamic> args) {
  final explicit = args['type'];
  if (explicit is String && explicit.isNotEmpty) {
    return TaskType.fromCode(explicit);
  }
  final text = '${args['title'] ?? ''} ${args['description'] ?? ''}';
  if (RegExp(
    r'每天|每日|天天|每晚|每早|daily|every day',
    caseSensitive: false,
  ).hasMatch(text)) {
    return TaskType.daily;
  }
  return args['due_date'] != null ? TaskType.span : TaskType.todo;
}

Map<String, dynamic> normalizeAiTaskCreation(
  Map<String, dynamic> args, {
  DateTime? now,
}) {
  if ((args['action'] as String? ?? '').trim().toLowerCase() != 'create') {
    return args;
  }
  final type = aiCreateTaskType(args);
  final result = Map<String, dynamic>.from(args)..['type'] = type.code;
  if (type == TaskType.daily || type == TaskType.span) {
    if (result['start_date'] == null) {
      result['start_date'] = dateOnlyToString(now ?? DateTime.now());
    }
  }
  if (type == TaskType.todo || type == TaskType.daily) {
    result.putIfAbsent('due_date', () => null);
  }
  return result;
}
