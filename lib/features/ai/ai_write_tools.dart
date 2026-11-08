import 'dart:convert';

import 'ai_tool_context.dart';
import 'ai_task_photos.dart';

import '../../data/models/course.dart';
import '../../data/models/date_utils.dart';
import '../../data/models/semester.dart';
import '../../data/models/task.dart';
import '../../data/repositories/task_repository.dart';
import '../../data/repositories/timetable_repository.dart';
import '../../services/ai/models/ai_tool.dart';
import '../../services/audio/complete_sound.dart';
import '../../services/notifications/notification_providers.dart';
import '../settings/settings_providers.dart' as settings_providers;
import '../schedule/schedule_providers.dart';
import '../timetable/color_utils.dart' show kCourseColorPalette;
import '../timetable/timetable_providers.dart';

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
    this.swatchHexOf,
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
  /// 仅部分工具支持（如 save_task 的 create 参数自含）；为空则卡片不可编辑。
  final String Function(Map<String, dynamic> args)? describeQuick;

  /// 参数 → 确认卡片上的人类可读描述（一句话）。
  final Future<String> Function(AiToolContext ref, Map<String, dynamic> args)
  describe;

  /// 参数 → 确认卡片上「本次将变成的颜色」预览色块的归一化 `#RRGGBB`；
  /// 无颜色变更（未涉及该字段 / 清除颜色）返回 null。
  ///
  /// 从**参数**直取，不经文案字符串解析——文案措辞随文案改动而变，
  /// 色块不能跟着忽有忽无。仅 save_course 的 update 实现（其余保持 null）。
  final String? Function(Map<String, dynamic> args)? swatchHexOf;

  /// 用户确认后执行，返回回传给模型的结果 JSON 文本。
  final Future<String> Function(AiToolContext ref, Map<String, dynamic> args)
  execute;

  /// OpenAI tools[] 数组元素。
  Map<String, dynamic> toSchema() => functionTool(
    name: name,
    description: description,
    parameters: parameters,
  );
}

/// 全部写工具。
///
/// 只有两条：日程类 [save_task] 与课程类 [save_course]，各自用 action 区分
/// 新建 / 修改 / 删除。合并后 schema 里重复的字段描述只出现一次，
/// 每轮请求固定少发一大段（见两个工具定义上的注释）。
final List<AiWriteTool> aiWriteTools = <AiWriteTool>[
  _saveTaskTool,
  _saveCourseTool,
];

/// 按名查找写工具；不是写工具返回 null。
AiWriteTool? findAiWriteTool(String name) {
  for (final AiWriteTool t in aiWriteTools) {
    if (t.name == name) return t;
  }
  return null;
}

// ---------------------------------------------------------------- 工具定义

/// 日程类写工具：新建 / 修改 / 改完成状态 / 删除，用 action 区分。
///
/// 合并理由（方案 A）：7 个写工具的 schema 原本占全部工具说明书的七成，
/// 且每次请求都要整份重发。合并成「日程」「课程」两条之后，模型看到的是
/// 一份共享的参数表 + 一句 action 说明，重复的字段描述只出现一次——
/// 而一次提问往往要串行发 2~3 轮，省下的开销每轮都吃。
///
/// action 决定的动作与原工具一一对应：
/// - `create` ← 原 create_task（草稿可在确认面板里编辑）
/// - `update` ← 原 update_task（草稿可在确认面板里编辑）
/// - `complete` ← 原 set_task_completed
/// - `delete` ← 原 delete_task（**不可恢复**）
///
/// 有 action 才校验/执行：模型若忘了传 action，validate 返回明确错误让它自纠，
/// 不会落到「默认建一条空任务」这种危险行为上。
final AiWriteTool _saveTaskTool = AiWriteTool(
  name: 'save_task',
  label: '日程',
  description:
      '提交日程/待办/每日打卡的操作草稿，由 App 校验并在用户确认后执行。'
      'action：create=新建、update=修改、complete=改完成状态、delete=删除（不可恢复）。'
      'type：scheduled=定时日程（建议带 due_time）/ todo=待办 / '
      'daily=每日打卡（区间用 start_date 到 due_date）/ '
      'span=一次性跨期（必须给 start_date）。'
      '用户未说清日期或标题时先询问，不要替用户猜。',
  parameters: <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'action': <String, dynamic>{
        'type': 'string',
        'enum': <String>['create', 'update', 'complete', 'delete'],
        'description': 'create=新建、update=修改、complete=改完成状态、delete=删除（不可恢复）',
      },
      'task_id': <String, dynamic>{
        'type': 'integer',
        'description':
            '要改/删/标记完成的任务 id（来自 query）：update / complete / delete 必填，'
            '不要凭记忆编造',
      },
      'completed': <String, dynamic>{
        'type': 'boolean',
        'description': '仅 action=complete：true=标记完成，false=恢复未完成',
      },
      'title': <String, dynamic>{
        'type': 'string',
        'description': '标题（create 必填；update 为新标题）',
      },
      'type': <String, dynamic>{
        'type': 'string',
        'enum': <String>['scheduled', 'todo', 'daily', 'span'],
        'description': 'todo=待办；scheduled=定时；daily=每日分别打卡；span=跨期只完成一次，需 start_date 与 due_date。每天提醒不改变任务类型。缺省 todo',
      },
      'due_date': <String, dynamic>{
        'type': 'string',
        'description': '截止日期 yyyy-MM-dd（create 必填）',
      },
      'due_time': <String, dynamic>{
        'type': 'string',
        'description': '截止时刻 HH:mm（scheduled 建议）',
      },
      'start_date': <String, dynamic>{
        'type': 'string',
        'description': '起始日期 yyyy-MM-dd（daily/span 用）',
      },
      'priority': <String, dynamic>{
        'type': 'string',
        'enum': <String>['normal', 'important', 'urgent'],
        'description': '优先度，缺省 normal',
      },
      'description': <String, dynamic>{'type': 'string', 'description': '备注'},
      'photo_mode': <String, dynamic>{
        'type': 'string',
        'enum': ['keep', 'append', 'replace', 'remove', 'clear'],
        'description':
            '仅create/update。修改时默认keep保留旧图；只有用户明确要求补图、换图、删图时设置。'
            'append追加本次照片；replace用本次照片替换旧图；remove移除指定旧图；clear清空。旧图内容本轮不可识读。',
      },
      'photo_indices': <String, dynamic>{
        'type': 'array',
        'items': {'type': 'integer', 'minimum': 1, 'maximum': 4},
        'description':
            '本次发送照片的序号，从1起，最多4项，不得使用历史图或文件路径。'
            '创建默认附本次照片；批量创建为各项分别建议图片序号，不确定归属则省略交用户选择；[]表示不附图。',
      },
      'remove_photo_indices': <String, dynamic>{
        'type': 'array',
        'items': {'type': 'integer', 'minimum': 1, 'maximum': 4},
        'description': '修改时明确删除的旧照片序号，从1起；需用户明确指出，不能猜测旧图内容。',
      },
      'remind_time': <String, dynamic>{
        'type': 'string',
        'description':
            '**每天**提醒的时刻 HH:mm（24 小时制）：用户只说某个钟点、或说'
            '"每天提醒我"时用它（"8点提醒我"→"08:00"）；"提前X分钟提醒"且已知'
            '起止时刻时换算成时刻（8:00 提前 10 分钟 → "07:50"）。'
            '从该时刻起每天提醒，直到任务完成（区间型到区间结束）。'
            'update 时传 "" 表示清除提醒；不传=不提醒（create）/保持原值（update）。'
            '与 remind_at 互斥，只传一个；提醒不要写进标题或备注。',
      },
      'remind_at': <String, dynamic>{
        'type': 'string',
        'description':
            '**只提醒一次**的时刻 "yyyy-MM-dd HH:mm"（日期不能用"明天"等相对说法，'
            '且必须晚于现在）：用户说"X月X日X点提醒我一次""只在那天提醒我"时用它。'
            'update 时传 "" 表示清除提醒。与 remind_time 互斥，只传一个。',
      },
    },
    'required': <String>['action'],
  },
  validate: _validateSaveTask,
  intentKey: _saveTaskIntentKey,
  describeQuick: (Map<String, dynamic> args) =>
      _saveTaskActionOf(args) == 'create' ? _describeCreateTaskSync(args) : '',
  describe: _describeSaveTask,
  execute: _executeSaveTask,
);

/// 课表课程类写工具：新建 / 修改 / 删除，用 action 区分。
///
/// 对应关系：`create` ← 原 create_course（草稿可在面板里编辑）、
/// `update` ← 原 update_course（**不可**在面板里编辑，与日程类不对称，
/// 原样保留）、`delete` ← 原 delete_course（删整门课的**全部周次**）。
final AiWriteTool _saveCourseTool = AiWriteTool(
  name: 'save_course',
  label: '课程',
  description:
      '提交课程操作草稿，由 App 校验并在用户确认后执行。'
      'action：create=新建、update=修改、delete=删除整门课（不可恢复，'
      '不是取消某一天的课）。'
      'weekday：1=周一 … 7=周日；**周次缺省为整学期**（第1周到最后），'
      '用户只说某一天（"今晚""周六"）时要显式给出那一天的 start_week=end_week；'
      'week_type：every=每周/odd=单周/even=双周/custom=自定义（配合 week_list）。',
  parameters: <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'action': <String, dynamic>{
        'type': 'string',
        'enum': <String>['create', 'update', 'delete'],
        'description': 'create=新建、update=修改、delete=删除整门课（不可恢复）',
      },
      'course_id': <String, dynamic>{
        'type': 'integer',
        'description': '要改/删的课程 id（来自 query），update / delete 必填',
      },
      'name': <String, dynamic>{'type': 'string', 'description': '课程名'},
      'weekday': <String, dynamic>{
        'type': 'integer',
        'description': '上课日：1=周一 … 7=周日',
      },
      'start_period': <String, dynamic>{
        'type': 'integer',
        'description': '起始节次',
      },
      'end_period': <String, dynamic>{'type': 'integer', 'description': '结束节次'},
      'location': <String, dynamic>{'type': 'string', 'description': '教室'},
      'teacher': <String, dynamic>{'type': 'string', 'description': '教师'},
      'start_week': <String, dynamic>{
        'type': 'integer',
        'description': '开始周，缺省 1（临时调课时填那一天所在周）',
      },
      'end_week': <String, dynamic>{
        'type': 'integer',
        'description': '结束周，缺省学期总周数（临时调课时与 start_week 填同一周）',
      },
      'week_type': <String, dynamic>{
        'type': 'string',
        'enum': <String>['every', 'odd', 'even', 'custom'],
        'description': '周次类型：每周/单周/双周/自定义，缺省 every',
      },
      'week_list': <String, dynamic>{
        'type': 'array',
        'items': <String, dynamic>{'type': 'integer'},
        'description': '自定义周序列（week_type=custom 时用，如 [1,3,5]）',
      },
      'color': <String, dynamic>{
        'type': 'string',
        'description':
            '课程颜色（update 用）：色名（红/粉/紫/蓝紫/蓝/浅蓝/青/绿/橙/棕/灰，'
            '可带「色」后缀如「蓝色」）、#RRGGBB（如 #64B5F6），或「无色」清除颜色',
      },
    },
    'required': <String>['action'],
  },
  validate: _validateSaveCourse,
  intentKey: _saveCourseIntentKey,
  describeQuick: (Map<String, dynamic> args) =>
      _saveCourseActionOf(args) == 'create'
      ? _describeCreateCourseSync(args)
      : '',
  describe: _describeSaveCourse,
  execute: _executeSaveCourse,
  swatchHexOf: (Map<String, dynamic> args) =>
      _saveCourseActionOf(args) == 'update' ? _courseSwatchHex(args) : null,
);

/// 解析 `action`；不是 [allowed] 里的值（含缺失、类型不对）返回 null。
String? _actionOf(Map<String, dynamic> args, Set<String> allowed) {
  final Object? raw = args['action'];
  if (raw is! String) return null;
  final String a = raw.trim().toLowerCase();
  return allowed.contains(a) ? a : null;
}

/// 日程类允许的 action。
const Set<String> _taskActions = <String>{
  'create',
  'update',
  'complete',
  'delete',
};

/// 课程类允许的 action。
const Set<String> _courseActions = <String>{'create', 'update', 'delete'};

/// save_task 的 action（缺失 / 非法返回 null）。
String? _saveTaskActionOf(Map<String, dynamic> args) =>
    _actionOf(args, _taskActions);

/// save_course 的 action（缺失 / 非法返回 null）。
String? _saveCourseActionOf(Map<String, dynamic> args) =>
    _actionOf(args, _courseActions);

/// action 缺失或非法时的错误文案（回传给模型自纠）。
String? _actionError(Map<String, dynamic> args, Set<String> allowed) {
  final Object? raw = args['action'];
  if (raw is String && allowed.contains(raw.trim().toLowerCase())) return null;
  return 'action 缺失或无效，必须是 ${allowed.join(' / ')} 之一';
}

// ---------------------------------------------------------------- 实现

// ------------------------------------------------------------ save_task 分派
//
// 合并后两条工具共用一份参数表，因此「哪些参数对哪个 action 有约束」必须在
// 分派处补齐：各 action 的校验、意图键、文案、执行体仍是原来那一套函数，
// 只是把入参范围收窄，语义与合并前逐条对齐。
//   create   → _validateCreateTask / _describeCreateTaskSync / _executeCreateTask
//   update   → _validateUpdateTask / _describeUpdateTask / _executeUpdateTask
//   complete → _validateSetCompleted / _describeSetCompleted / _executeSetCompleted
//   delete   → _validateDeleteTask / _describeDeleteTask / _executeDeleteTask

/// save_task 校验：先查 action，再按 action 分派到各自的校验。
///
/// ⚠️ 2026-11-02 真机回归：合并初期这里曾用一张「只属于新建的字段」清单
/// （title / type / due_date / due_time / start_date）在 update 时直接拒绝，
/// 结果「把刚才那条改成后天到期」被模型连试 3 次全部拦死，用户看到的是
/// 一次彻底失败。禁止「改日期 / 改标题」毫无道理（合并前的 update_task 本来
/// 就支持），现已废除拦截。**不要再把日期类字段加回这类黑名单。**
String? _validateSaveTask(Map<String, dynamic> args) {
  final String? actionError = _actionError(args, _taskActions);
  if (actionError != null) return actionError;
  final photoError = validateTaskPhotoArgs(args);
  if (photoError != null) return photoError;
  switch (_saveTaskActionOf(args)) {
    case 'create':
      // 新建时 task_id / completed 没有意义，静默忽略，不报错。
      return _validateCreateTask(args);
    case 'update':
      // 允许改 title / type / due_date / due_time / start_date，逐项校验。
      // ⚠️ 曾在此处把上述字段一律当 create-only 拒绝，导致真机上「把刚才
      // 那条改成后天到期」被拦死（2026-11-02）。反向混用（想新建却写成
      // update）由 _validateUpdateTask 的「缺少有效 task_id」兜住。
      return _validateUpdateTask(args);
    case 'complete':
      return _validateSetCompleted(args);
    case 'delete':
      return _validateDeleteTask(args);
    default:
      return actionError;
  }
}

/// save_task 意图键：同名工具的多个 action 必须互不冲突，故以前缀区分。
///
/// `create` 的键沿用合并前只含标题的宽口径（同一批里同标题的重复新建
/// 只确认一次是有意为之），其余 action 沿用原作者写好的后半段。
String _saveTaskIntentKey(Map<String, dynamic> args) {
  final String action = _saveTaskActionOf(args) ?? 'invalid';
  switch (action) {
    case 'create':
      return 'save_task.create|${(args['title'] as String?)?.trim() ?? ''}';
    case 'update':
      return 'save_task.update|${_taskIdOf(args)}|'
          '${jsonEncode(_taskChanges(args))}';
    case 'complete':
      return 'save_task.complete|${_taskIdOf(args)}|${args['completed'] == true}';
    case 'delete':
      return 'save_task.delete|${_taskIdOf(args)}';
    default:
      return 'save_task.invalid|${jsonEncode(args)}';
  }
}

/// save_task 确认卡片文案（按 action 分派）。
Future<String> _describeSaveTask(
  AiToolContext ref,
  Map<String, dynamic> args,
) async {
  switch (_saveTaskActionOf(args)) {
    case 'create':
      return '${_describeCreateTaskSync(args)}${_taskPhotoSummary(args)}';
    case 'update':
      return '${await _describeUpdateTask(ref, args)}${_taskPhotoSummary(args)}';
    case 'complete':
      return _describeSetCompleted(ref, args);
    case 'delete':
      return _describeDeleteTask(ref, args);
    default:
      return '日程操作（参数不完整）';
  }
}

String _taskPhotoSummary(Map<String, dynamic> args) {
  final draft = AiTaskPhotoDraft.fromArgs(args);
  return draft == null ? '' : ' · ${draft.summary}';
}

/// save_task 执行（按 action 分派）。
Future<String> _executeSaveTask(
  AiToolContext ref,
  Map<String, dynamic> args,
) async {
  switch (_saveTaskActionOf(args)) {
    case 'create':
      return _executeCreateTask(ref, args);
    case 'update':
      return _executeUpdateTask(ref, args);
    case 'complete':
      return _executeSetCompleted(ref, args);
    case 'delete':
      return _executeDeleteTask(ref, args);
    default:
      return jsonEncode(<String, dynamic>{
        'status': 'error',
        'message': 'action 缺失或无效，未执行任何改动',
      });
  }
}

// ---------------------------------------------------------- save_course 分派
//
//   create → _validateCreateCourse / _describeCreateCourseSync / _executeCreateCourse
//   update → _validateUpdateCourse / _describeUpdateCourse / _executeUpdateCourse
//   delete → _validateDeleteCourse / _describeDeleteCourse / _executeDeleteCourse

/// save_course 校验：先查 action，再按 action 收窄参数。
String? _validateSaveCourse(Map<String, dynamic> args) {
  final String? actionError = _actionError(args, _courseActions);
  if (actionError != null) return actionError;
  switch (_saveCourseActionOf(args)) {
    case 'create':
      // 新建时 course_id / color 无意义；color 忽略（新课程用默认待选色）。
      return _validateCreateCourse(args);
    case 'update':
      // update_course 原本就支持改 color 在内的全部字段，这里原样交给它；
      // 「什么都没传」由 _validateUpdateCourse 自己拦。
      return _validateUpdateCourse(args);
    case 'delete':
      return _validateDeleteCourse(args);
    default:
      return actionError;
  }
}

/// save_course 意图键（前缀区分 action，后半段沿用原作者写法）。
String _saveCourseIntentKey(Map<String, dynamic> args) {
  final String action = _saveCourseActionOf(args) ?? 'invalid';
  switch (action) {
    case 'create':
      return 'save_course.create|'
          '${(args['name'] as String?)?.trim() ?? ''}|'
          '${(args['weekday'] as num?)?.toInt()}|'
          '${(args['start_period'] as num?)?.toInt()}-'
          '${(args['end_period'] as num?)?.toInt()}';
    case 'update':
      return 'save_course.update|${_courseIdOf(args)}|'
          '${jsonEncode(_courseChanges(args))}';
    case 'delete':
      return 'save_course.delete|${_courseIdOf(args)}';
    default:
      return 'save_course.invalid|${jsonEncode(args)}';
  }
}

/// save_course 确认卡片文案（按 action 分派）。
Future<String> _describeSaveCourse(
  AiToolContext ref,
  Map<String, dynamic> args,
) async {
  switch (_saveCourseActionOf(args)) {
    case 'create':
      return _describeCreateCourseSync(args);
    case 'update':
      return _describeUpdateCourse(ref, args);
    case 'delete':
      return _describeDeleteCourse(ref, args);
    default:
      return '课程操作（参数不完整）';
  }
}

/// save_course 执行（按 action 分派）。
Future<String> _executeSaveCourse(
  AiToolContext ref,
  Map<String, dynamic> args,
) async {
  switch (_saveCourseActionOf(args)) {
    case 'create':
      return _executeCreateCourse(ref, args);
    case 'update':
      return _executeUpdateCourse(ref, args);
    case 'delete':
      return _executeDeleteCourse(ref, args);
    default:
      return jsonEncode(<String, dynamic>{
        'status': 'error',
        'message': 'action 缺失或无效，未执行任何改动',
      });
  }
}

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
  final String timeText = time is String && time.trim().isNotEmpty
      ? ' ${time.trim()}'
      : '';
  final String remindText = _remindText(args);
  return '新建$typeLabel「${title.isEmpty ? '（无标题）' : title}」'
      '· ${due == null ? '日期无效' : _fmtDateCn(due)}$timeText$remindText';
}

Future<String> _executeCreateTask(
  AiToolContext ref,
  Map<String, dynamic> args,
) async {
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
  final String? dueTime = time is String && time.trim().isNotEmpty
      ? time.trim()
      : null;
  final Object? remind = args['remind_time'];
  final String? remindTime = remind is String && remind.trim().isNotEmpty
      ? remind.trim()
      : null;
  // 「只提醒一次」：与 remind_time 互斥（校验层已挡，这里兜底取更具体的那个）。
  final DateTime? remindOnceAt = _parseDateTimeMinutes(args['remind_at']);
  Priority priority = Priority.normal;
  final Object? p = args['priority'];
  if (p is String) {
    try {
      priority = Priority.fromCode(p);
    } on FormatException {
      // 保持普通。
    }
  }

  final AiTaskPhotoFiles photos;
  try {
    photos = await materializeTaskPhotos(ref, args);
  } catch (error) {
    return _taskPhotoFailure(error);
  }
  try {
    final Task task = Task(
      title: title,
      description: args['description'] is String
          ? args['description'] as String
          : '',
      imagePaths: photos.imagePaths,
      type: type,
      dueDate: due,
      dueTime: dueTime,
      priority: priority,
      startDate:
          start ??
          (type == TaskType.daily || type == TaskType.span ? due : null),
      // 提醒落库口径与任务表单一致（见 task_form_page.dart `_save`）：
      // - 「每天」→ daily_remind_time + reminder_repeat=daily；
      // - 「一次」→ remind_once_at + reminder_repeat=once（daily_remind_time 留空）；
      // - 都不传 → 三个字段全空（不提醒）。
      // 与界面一样按类型分流：daily 类型只写每日时刻（它的 UI 只有「每天」）。
      // 未提供任何提醒参数时不写（null），避免把 daily 任务的日提醒清空。
      dailyRemindTime: type == TaskType.daily || remindOnceAt != null
          ? null
          : remindTime,
      reminderRepeat: remindOnceAt != null
          ? ReminderRepeat.once
          : (!_hasReminderArg(args)
                ? null
                : (remindTime != null ? ReminderRepeat.daily : null)),
      remindOnceAt: type == TaskType.daily ? null : remindOnceAt,
    );
    final int? id = await ref.read(taskPersistenceProvider).save(task);
    if (id == null) {
      return jsonEncode(<String, dynamic>{'status': 'error', 'error': '保存失败'});
    }
    return jsonEncode(<String, dynamic>{
      'status': 'created',
      'task_id': id,
      'title': title,
      'photo_count': photos.imagePaths.length,
    });
  } finally {
    // 保存结果不确定时也先检查实际引用，不能删掉已经写入任务的图片。
    await releaseTaskPhotoCopies(ref, photos.createdPaths);
  }
}

String _taskPhotoFailure(Object error) => jsonEncode(<String, dynamic>{
  'status': 'error',
  'error': error is FormatException
      ? error.message
      : '照片未保存，请检查图片后重新确认；未执行本项修改',
});

Future<String> _describeSetCompleted(
  AiToolContext ref,
  Map<String, dynamic> args,
) async {
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
  AiToolContext ref,
  Map<String, dynamic> args,
) async {
  final int? id = _taskIdOf(args);
  if (id == null) {
    return jsonEncode(<String, dynamic>{
      'status': 'error',
      'error': '缺少 task_id',
    });
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
    await playCompletionSoundUsing(
      ref.read(settings_providers.settingsRepositoryProvider),
      () => ref.read(completionSoundPlayerProvider),
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

// ---------------------------------------------------------------- delete_task

String? _validateDeleteTask(Map<String, dynamic> args) =>
    _taskIdOf(args) == null ? '缺少有效的 task_id（整数）；请先用 query 查出要删除的那条' : null;

Future<String> _describeDeleteTask(
  AiToolContext ref,
  Map<String, dynamic> args,
) async {
  final int? id = _taskIdOf(args);
  if (id == null) return '删除日程';
  Task? orig;
  try {
    orig = await ref.read(taskRepositoryProvider).getTaskById(id);
  } catch (_) {
    // 查不到按未找到展示。
  }
  if (orig == null) return '删除日程 #$id（未找到该日程）';
  final Object? time = orig.dueTime;
  final String timeText = time is String && time.trim().isNotEmpty
      ? ' ${time.trim()}'
      : '';
  return '删除日程「${orig.title}」· ${_fmtDateCn(orig.dueDate)}$timeText · 不可恢复';
}

Future<String> _executeDeleteTask(
  AiToolContext ref,
  Map<String, dynamic> args,
) async {
  final int? id = _taskIdOf(args);
  if (id == null) {
    return jsonEncode(<String, dynamic>{
      'status': 'error',
      'error': '缺少 task_id',
    });
  }
  final Task? existing = await ref.read(taskRepositoryProvider).getTaskById(id);
  if (existing == null) {
    return jsonEncode(<String, dynamic>{
      'status': 'not_found',
      'note': '任务不存在（id=$id）',
    });
  }
  // 复用日程模块的删除入口：内含提醒取消与列表失效，避免留下幽灵提醒。
  await ref.read(taskPersistenceProvider).delete(id);
  return jsonEncode(<String, dynamic>{
    'status': 'deleted',
    'task_id': id,
    'title': existing.title,
  });
}

// ---------------------------------------------------------------- update_task

/// update_task 参数中允许修改的字段（顺序稳定，供意图键序列化）。
const List<String> _taskChangeFields = <String>[
  'title',
  'type',
  'due_date',
  'due_time',
  'start_date',
  'priority',
  'description',
  'remind_time',
  'remind_at',
  'photo_mode',
  'photo_indices',
  'remove_photo_indices',
];

Map<String, dynamic> _taskChanges(Map<String, dynamic> args) =>
    <String, dynamic>{
      for (final String k in _taskChangeFields)
        if (args.containsKey(k)) k: args[k],
      if (hasTaskPhotoChanges(args)) '_photos': taskPhotoChangeSignature(args),
    };

String? _validateUpdateTask(Map<String, dynamic> args) {
  if (_taskIdOf(args) == null) return '缺少有效的 task_id（整数）';
  bool hasAny = hasTaskPhotoChanges(args);
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
  if (args.containsKey('remind_time')) {
    final String? err = _validateRemindTime(args['remind_time']);
    if (err != null) return err;
    hasAny = true;
  }
  final String? remindErr = _validateRemindPair(args);
  if (remindErr != null) return remindErr;
  if (args.containsKey('remind_at')) hasAny = true;
  if (!hasAny) return '未指定任何要修改的字段';
  return null;
}

/// 校验提醒时刻参数：`HH:mm` 合法，或空串（表示清除提醒/不提醒）。
String? _validateRemindTime(Object? value) {
  if (value is! String) return 'remind_time 需为字符串（HH:mm）';
  final String v = value.trim();
  if (v.isEmpty) return null; // 空串 = 清除提醒
  if (!isValidTime24h(v)) return 'remind_time 格式无效（需 HH:mm，24 小时制）';
  return null;
}

/// 确认卡片上的提醒文案（无提醒返回空串）。
///
/// 两种模式各自成句：
/// - `remind_time`（每天）→ ` · 每天 08:00 提醒`
/// - `remind_at`（一次性）→ ` · 11月3日 14:00 提醒一次`（跨年补年份）
///
/// 两者同时出现时以 `remind_at` 为准（语义更具体）；校验层已禁止同时传，
/// 这里只是兜底，不让卡片出现两句互相矛盾的提醒。
String _remindText(Map<String, dynamic> args) {
  final Object? once = args['remind_at'];
  if (once is String && once.trim().isNotEmpty) {
    final String v = once.trim();
    final DateTime? at = _parseDateTimeMinutes(v);
    if (at == null) return ' · 提醒时刻无效';
    return ' · ${_fmtDateCn(at)} ${_fmtTime(at)} 提醒一次';
  }
  final Object? daily = args['remind_time'];
  if (daily is! String || daily.trim().isEmpty) return '';
  final String v = daily.trim();
  return isValidTime24h(v) ? ' · 每天 $v 提醒' : ' · 提醒时刻无效';
}

bool _isSameDate(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 已存任务的提醒现状（用于确认卡片「提醒 → …」的对比）。
///
/// 口径与 [TaskDetailPage] 的 `_remindText` 一致：一次性优先，其次每日，
/// 最后才是旧版 offset 提醒；都没有 → 空串（不提醒）。
String _describeTaskReminder(Task task) {
  if (task.reminderRepeat == ReminderRepeat.once) {
    final DateTime? at = task.remindOnceAt;
    if (at == null) return '';
    return '${_fmtDateCn(at)} ${_fmtTime(at)} 提醒一次';
  }
  final String? hhmm = task.dailyRemindTime;
  if (hhmm != null && hhmm.isNotEmpty) return '每天 $hhmm 提醒';
  return '';
}

Future<String> _describeUpdateTask(
  AiToolContext ref,
  Map<String, dynamic> args,
) async {
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
  if (args.containsKey('remind_time') || args.containsKey('remind_at')) {
    final String nt = _remindText(args).replaceFirst(' · ', '');
    final String old = _describeTaskReminder(orig);
    if (nt != old) parts.add('提醒 → ${nt.isEmpty ? '不提醒' : nt}');
  }
  if (parts.isEmpty) return '修改「${orig.title}」（内容无变化）';
  return '修改「${orig.title}」：${parts.join('；')}';
}

Future<String> _executeUpdateTask(
  AiToolContext ref,
  Map<String, dynamic> args,
) async {
  final int? id = _taskIdOf(args);
  if (id == null) {
    return jsonEncode(<String, dynamic>{
      'status': 'error',
      'error': '缺少 task_id',
    });
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

  // 提醒：三字段必须**一起**决定，逐个 copyWith 无法表达「清除」——
  // `copyWith` 的 null 语义是「保持原值」，传 null 等于没改（历史 bug：
  // 模型要求「取消提醒」时实际没清掉）。故先算出目标三元组，再整体重建。
  //
  // 口径与任务表单 `_save` 一致：
  // - remind_time 非空 → 每天（reminder_repeat=daily, remind_once_at 清空）
  // - remind_at 非空   → 一次性（reminder_repeat=once, daily_remind_time 清空）
  // - 显式传空串       → 不提醒（两个字段都清空）
  // - 都没传           → 保持原样
  final bool hasOnceArg = args.containsKey('remind_at');
  final bool hasDailyArg = args.containsKey('remind_time');
  final String onceRaw = hasOnceArg
      ? (args['remind_at'] as String? ?? '').trim()
      : '';
  final String dailyRaw = hasDailyArg
      ? (args['remind_time'] as String? ?? '').trim()
      : '';
  final DateTime? onceAt = onceRaw.isEmpty
      ? null
      : _parseDateTimeMinutes(onceRaw);
  final String? dailyHhmm = dailyRaw.isEmpty ? null : dailyRaw;

  // 目标提醒三元组：
  // - 传了 remind_at 非空 → 一次性；
  // - 否则传了 remind_time 非空 → 每天；
  // - 否则只要**动了**提醒参数（含任意一个空串）→ 不提醒，三字段全空；
  // - 没动 → 沿用原值。
  // 关键：清除时必须把 daily_remind_time 一并清掉，否则 reminder_repeat
  // 落成 null 后调度器会按「有每日时刻」兜底成每天提醒，清除就失效了。
  final bool reminderTouched = hasOnceArg || hasDailyArg;
  final bool clearAll = reminderTouched && onceAt == null && dailyHhmm == null;
  final String? nextDailyRemindTime = clearAll
      ? null
      : (dailyHhmm ??
            // 切成一次性时必须把每日时刻清掉：调度器分支顺序里
            // `reminderRepeat == once` 虽在 `dailyRemindTime != null` 之前，
            // 但详情页/确认卡/再次编辑都按「两个字段是否有值」判读，
            // 留着旧值会让任务看起来像每天又在提醒一次，切回每天时也会
            // 悄悄用回旧时刻。
            (onceAt != null ? null : t.dailyRemindTime));
  final ReminderRepeat? nextRepeat = clearAll
      ? null
      : (onceAt != null
            ? ReminderRepeat.once
            : (dailyHhmm != null ? ReminderRepeat.daily : t.reminderRepeat));
  final DateTime? nextOnceAt = clearAll
      ? null
      : (onceAt ?? (dailyHhmm != null ? null : t.remindOnceAt));

  // 旧版 offset 提醒只在「模型没提任何提醒」时保留：一旦模型改写提醒，
  // 旧字段会抢在每日/一次性分支之前命中（见调度器分支顺序），故直接置空。
  // 注：`copyWith` 无法表达 null，这里不动 base，只在重建时传 null。
  final Task base = t;

  final AiTaskPhotoFiles photos;
  try {
    photos = await materializeTaskPhotos(ref, args, existing: orig);
  } catch (error) {
    return _taskPhotoFailure(error);
  }
  try {
    final Task toSave = Task(
      id: base.id,
      title: base.title,
      description: base.description,
      imagePaths: photos.imagePaths,
      type: base.type,
      dueDate: base.dueDate,
      dueTime: base.dueTime,
      startDate: base.startDate,
      priority: base.priority,
      courseId: base.courseId,
      completed: base.completed,
      completedAt: base.completedAt,
      createdAt: base.createdAt,
      // 旧版 offset 提醒（remind_offset_min / remind_date）：模型一旦改写提醒就
      // 一并清空（与界面「保存即清掉旧 offset」同口径）；没改写则原样保留，
      // 存量未编辑任务的原单次调度不受影响。
      remindOffsetMin: reminderTouched ? null : base.remindOffsetMin,
      remindDate: reminderTouched ? null : base.remindDate,
      dailyRemindTime: nextDailyRemindTime,
      reminderRepeat: nextRepeat,
      remindOnceAt: nextOnceAt,
    );

    final changed = await repo.updateTask(toSave);
    if (changed != 1) {
      return jsonEncode({'status': 'error', 'error': '任务不存在或已删除，未保存修改'});
    }
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
      'title': toSave.title,
      'photo_count': photos.imagePaths.length,
    });
  } finally {
    await releaseTaskPhotoCopies(ref, photos.createdPaths);
  }
}

// ------------------------------------------------------------- update_course

/// 中文色名 → 色板色值映射（AI 侧「色名」表达的唯一来源）。
///
/// 值一律取自课表模块的公共色板 [kCourseColorPalette]，**不另抄一份色值**——
/// 色板调整时此处自动跟随。键为归一化后的色名（已去掉「色」后缀），
/// 因此「蓝」与「蓝色」命中同一条目；「无色」等清除口径另见
/// [kCourseColorClearWords]。
final Map<String, String> kCourseColorNames = <String, String>{
  '红': kCourseColorPalette[0],
  '粉': kCourseColorPalette[1],
  '紫': kCourseColorPalette[2],
  '蓝紫': kCourseColorPalette[3],
  '蓝': kCourseColorPalette[4],
  '浅蓝': kCourseColorPalette[5],
  '青': kCourseColorPalette[6],
  '绿': kCourseColorPalette[7],
  '橙': kCourseColorPalette[8],
  '棕': kCourseColorPalette[9],
  '灰': kCourseColorPalette[10],
};

/// 「清除颜色」口径：这些输入归一化为空串（无色）。
const Set<String> kCourseColorClearWords = <String>{'无色', '透明', '清除'};

/// color 参数非法时的统一错误提示。
const String _kColorErrorText =
    'color 仅支持色名（红/粉/紫/蓝紫/蓝/浅蓝/青/绿/橙/棕/灰，可带「色」后缀）'
    '或 #RRGGBB，或用「无色」清除';

final RegExp _kHexColorPattern = RegExp(r'^[0-9a-fA-F]{6}$');

/// 归一化 `color` 参数 → 存储值；非法返回 null。
///
/// 返回 `''` 表示清除颜色，否则为大写带 `#` 的 `#RRGGBB`。
/// 接受：色名（含带「色」后缀的别名，如「蓝色」）、`#RRGGBB`/`RRGGBB`
/// （6 位 hex，大小写不限）、空串及「无色」/「透明」/「清除」。
String? parseAiCourseColor(Object? raw) {
  if (raw is! String) return null;
  final String s = raw.trim();
  if (s.isEmpty) return '';
  if (kCourseColorClearWords.contains(s)) return '';
  final String name = s.endsWith('色') && s.length > 1
      ? s.substring(0, s.length - 1)
      : s;
  final String? byName = kCourseColorNames[name];
  if (byName != null) return byName;
  final String body = s.startsWith('#') ? s.substring(1) : s;
  if (_kHexColorPattern.hasMatch(body)) return '#${body.toUpperCase()}';
  return null;
}

/// 色值 → 色名（命中色板时）；否则 null。用于确认卡文案。
String? _colorNameOf(String hex) {
  for (final MapEntry<String, String> e in kCourseColorNames.entries) {
    if (e.value == hex) return e.key;
  }
  return null;
}

/// 确认卡上的颜色文案：`颜色：蓝色（#64B5F6）` / `颜色：#123456` / `清除颜色`。
String _colorDisplay(String hex) {
  if (hex.isEmpty) return '清除颜色';
  final String? name = _colorNameOf(hex);
  return name == null ? '颜色：$hex' : '颜色：$name色（$hex）';
}

/// update_course 确认卡色块：本次将变成的颜色（归一化 `#RRGGBB`）。
///
/// 未传 color（不涉及颜色）或「清除颜色」（归一化为空串）→ null，不显示色块。
String? _courseSwatchHex(Map<String, dynamic> args) {
  if (!args.containsKey('color')) return null;
  final String? hex = parseAiCourseColor(args['color']);
  return (hex == null || hex.isEmpty) ? null : hex;
}

/// update_course 参数中允许修改的字段。
const List<String> _courseChangeFields = <String>[
  'name',
  'weekday',
  'start_period',
  'end_period',
  'location',
  'teacher',
  'start_week',
  'end_week',
  'week_type',
  'week_list',
  'color',
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
  if (args.containsKey('color')) {
    if (parseAiCourseColor(args['color']) == null) return _kColorErrorText;
    hasAny = true;
  }
  if (!hasAny) return '未指定任何要修改的字段';
  return null;
}

const List<String> _weekdayNames = <String>[
  '周一',
  '周二',
  '周三',
  '周四',
  '周五',
  '周六',
  '周日',
];

Future<String> _describeUpdateCourse(
  AiToolContext ref,
  Map<String, dynamic> args,
) async {
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
  if (args.containsKey('color')) {
    final String? hex = parseAiCourseColor(args['color']);
    if (hex != null && hex != orig.color) parts.add(_colorDisplay(hex));
  }
  if (parts.isEmpty) return '修改课程「${orig.name}」（内容无变化）';
  return '修改课程「${orig.name}」：${parts.join('；')}';
}

Future<String> _executeUpdateCourse(
  AiToolContext ref,
  Map<String, dynamic> args,
) async {
  final int? id = _courseIdOf(args);
  if (id == null) {
    return jsonEncode(<String, dynamic>{
      'status': 'error',
      'error': '缺少 course_id',
    });
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
    c = c.copyWith(
      weekList: <int>[
        for (final Object? e in args['week_list'] as List) (e as num).toInt(),
      ],
    );
  }
  if (args.containsKey('color')) {
    final String? hex = parseAiCourseColor(args['color']);
    if (hex != null) c = c.copyWith(color: hex);
  }

  await repo.updateCourse(c);
  ref.invalidate(coursesProvider);
  try {
    await ref.read(timetableReminderReschedulerProvider)();
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
  final int sp = args['start_period'] is num
      ? (args['start_period'] as num).toInt()
      : 1;
  final int ep = args['end_period'] is num
      ? (args['end_period'] as num).toInt()
      : sp;
  final String loc = (args['location'] as String?)?.trim() ?? '';
  final int sw = args['start_week'] is num
      ? (args['start_week'] as num).toInt()
      : 1;
  final int ew = args['end_week'] is num
      ? (args['end_week'] as num).toInt()
      : 0;
  final String weekText = ew > 0 ? (sw == ew ? '第$sw周' : '第$sw-$ew周') : '整学期';
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
  AiToolContext ref,
  Map<String, dynamic> args,
) async {
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
    return jsonEncode(<String, dynamic>{'status': 'error', 'error': '课程名为空'});
  }
  await repo.insertCourse(course);
  ref.invalidate(coursesProvider);
  try {
    await ref.read(timetableReminderReschedulerProvider)();
  } catch (_) {
    // 提醒重排失败不影响保存。
  }
  return jsonEncode(<String, dynamic>{
    'status': 'created',
    'name': course.name,
    'semester': semester.name,
  });
}

// ------------------------------------------------------------- delete_course

String? _validateDeleteCourse(Map<String, dynamic> args) =>
    _courseIdOf(args) == null
    ? '缺少有效的 course_id（整数）；请先用 query 查出要删除的那门课'
    : null;

Future<String> _describeDeleteCourse(
  AiToolContext ref,
  Map<String, dynamic> args,
) async {
  final int? id = _courseIdOf(args);
  if (id == null) return '删除课程';
  Course? orig;
  try {
    orig = await ref.read(timetableRepositoryProvider).getCourseById(id);
  } catch (_) {
    // 查不到按未找到展示。
  }
  if (orig == null) return '删除课程 #$id（未找到该课程）';
  // 同名多门课（如分单双周或不同教室）靠星期/节次/教室才能分清，必须带上。
  final String loc = orig.location.trim();
  final String detail =
      '${_weekdayNames[orig.weekday - 1]} ${orig.startPeriod}-${orig.endPeriod}节'
      '${loc.isEmpty ? '' : ' · $loc'}';
  // 同名课不止一门时必须把「还剩几门」说清楚，否则用户以为整门课删干净了
  //（2026-11-02 真机：删掉周六补课那门后，用户以为高等数学整学期都没了）。
  int sameName = 1;
  try {
    final Semester? cur = await ref.read(currentSemesterProvider.future);
    if (cur?.id != null) {
      final List<Course> all = await ref
          .read(timetableRepositoryProvider)
          .getCourses(cur!.id!);
      sameName = all.where((Course c) => c.name == orig!.name).length;
    }
  } catch (_) {
    // 查列表失败就不提示同名数，退回最小文案。
  }
  final String tail = sameName > 1 ? ' · 同名课尚有 ${sameName - 1} 门' : '';
  return '删除课程「${orig.name}」· $detail$tail · 不可恢复';
}

Future<String> _executeDeleteCourse(
  AiToolContext ref,
  Map<String, dynamic> args,
) async {
  final int? id = _courseIdOf(args);
  if (id == null) {
    return jsonEncode(<String, dynamic>{
      'status': 'error',
      'error': '缺少 course_id',
    });
  }
  final ITimetableRepository repo = ref.read(timetableRepositoryProvider);
  final Course? orig = await repo.getCourseById(id);
  if (orig == null) {
    return jsonEncode(<String, dynamic>{
      'status': 'not_found',
      'note': '课程不存在（id=$id）',
    });
  }
  await repo.deleteCourse(id);
  ref.invalidate(coursesProvider);
  // 删除后取消该课程全部提醒并重建其余提醒；失败不阻断删除结果
  //（与课程页删除同口径，见 features/timetable/course_form_page.dart）。
  try {
    await ref
        .read(notificationSchedulerProvider)
        .cancelAllRemindersFor(courseId: id);
    await ref.read(timetableReminderReschedulerProvider)();
  } catch (_) {
    // 忽略：提醒重排失败不影响删除结果。
  }
  return jsonEncode(<String, dynamic>{
    'status': 'deleted',
    'course_id': id,
    'name': orig.name,
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
        !const <String>[
          'scheduled',
          'todo',
          'daily',
          'span',
        ].contains(typeCode)) {
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
  // 每日打卡的提醒只有「每天」一种（UI 就是「每日提醒时刻」），一次性提醒无意义。
  if (type == 'daily') {
    final Object? once = args['remind_at'];
    if (once is String && once.trim().isNotEmpty) {
      return '每日打卡任务只支持每天重复的提醒（用 remind_time），不支持 remind_at';
    }
  }
  return _validateRemindPair(args);
}

/// set_task_completed 参数校验。
String? _validateSetCompleted(Map<String, dynamic> args) {
  return _taskIdOf(args) == null ? '缺少有效的 task_id（整数）' : null;
}

/// 提醒参数（两种表达）的互斥与格式校验；返回错误消息或 null（有效）。
///
/// 两种表达对应界面的两模式（PRD-日程模块 §10）：
/// - `remind_time`（`HH:mm`）→ 每天重复；
/// - `remind_at`（`yyyy-MM-dd HH:mm`）→ 只响一次，且必须晚于现在。
///
/// 同时传两者**直接判错**而不是悄悄取一个——模型据此自纠，用户也不会看到
/// 一张「明明说要提醒一次、卡片却写每天」的确认面板。
String? _validateRemindPair(Map<String, dynamic> args) {
  final Object? once = args['remind_at'];
  final Object? daily = args['remind_time'];
  final bool hasOnce = once is String && once.trim().isNotEmpty;
  final bool hasDaily = daily is String && daily.trim().isNotEmpty;
  if (hasOnce && hasDaily) {
    return '提醒只能用 remind_time（每天）或 remind_at（只提醒一次）'
        '其中之一表达，不要同时传';
  }
  if (hasDaily) {
    final String? err = _validateRemindTime(daily);
    if (err != null) return err;
  }
  if (hasOnce) {
    final String v = once.trim();
    final DateTime? at = _parseDateTimeMinutes(v);
    if (at == null) {
      return 'remind_at 格式无效（需 yyyy-MM-dd HH:mm，如 2026-11-03 14:00）';
    }
    if (!at.isAfter(DateTime.now())) {
      return 'remind_at 必须晚于现在（收到 $v，已过去）';
    }
  }
  return null;
}

/// 提醒参数（两种表达）是否出现在本次调用里，且都不是「空白/清除」。
///
/// 用于区分「模型没提提醒」与「模型明确要求不提醒」——前者不该改动
/// 任何提醒字段（daily 类型尤其不能被顺手清掉）。
bool _hasReminderArg(Map<String, dynamic> args) {
  final Object? once = args['remind_at'];
  final Object? daily = args['remind_time'];
  if (once is String && once.trim().isNotEmpty) return true;
  if (daily is String && daily.trim().isNotEmpty) return true;
  return false;
}

/// 解析「一次性提醒」时刻 `yyyy-MM-dd HH:mm`（秒/毫秒归零）；非法返回 null。
///
/// 分钟归零与调度侧 `NotificationScheduler.onceRemindAt` 的粒度一致。
DateTime? _parseDateTimeMinutes(Object? raw) {
  if (raw is! String) return null;
  final String v = raw.trim();
  if (v.isEmpty) return null;
  // DateTime.tryParse 接受 "2026-11-03 14:00"（也接受 T 分隔与秒）。
  final DateTime? parsed = DateTime.tryParse(v);
  if (parsed == null) return null;
  return DateTime(
    parsed.year,
    parsed.month,
    parsed.day,
    parsed.hour,
    parsed.minute,
  );
}

/// `HH:mm` 文本（与界面 `formatTimeOfDay` 同格式）。
String _fmtTime(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}';

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
