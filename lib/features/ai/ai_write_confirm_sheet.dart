import 'package:flutter/material.dart';

import 'ai_write_tools.dart';

/// 待确认的写操作条目（S8 草稿卡）。
///
/// - [tool]/[args]：发起时的写调用（[args] 可被草稿编辑替换）；
/// - [description]：人类可读文案（编辑保存后经 tool.describeQuick 重算）；
/// - [editable]：是否开放草稿编辑（需工具支持 describeQuick，如
///   create_task / create_course）。
class AiWriteConfirmItem {
  AiWriteConfirmItem({
    required this.tool,
    required this.args,
    required this.description,
  })  : assert(
          tool.describeQuick != null || tool.name != 'create_task',
          'create_task 必须提供 describeQuick 以支持草稿编辑',
        ),
        editable = tool.describeQuick != null &&
            _editableTools.contains(tool.name);

  /// 支持面板内草稿编辑的工具（各配有专用编辑对话框）。
  static const Set<String> _editableTools = <String>{
    'create_task',
    'update_task',
    'create_course',
  };

  final AiWriteTool tool;
  Map<String, dynamic> args;
  String description;
  final bool editable;
}

/// 弹出写操作逐条确认面板（模态，不可点外部/下拉关闭）。
///
/// 返回与 [items] 等长的「执行用参数」列表：勾选且未取消的条目为其
/// （可能被编辑过的）args；跳过/取消勾选的条目为 null。点「全部跳过」
/// 返回全 null。
Future<List<Map<String, dynamic>?>> showAiWriteConfirmSheet(
  BuildContext context, {
  required List<AiWriteConfirmItem> items,
}) async {
  final List<bool> selected = List<bool>.filled(items.length, true);
  final List<Map<String, dynamic>?>? result =
      await showModalBottomSheet<List<Map<String, dynamic>?>>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) {
      return StatefulBuilder(
        builder: (BuildContext ctx, void Function(VoidCallback) setSheetState) {
          final ThemeData theme = Theme.of(ctx);
          int selectedCount = selected.where((bool v) => v).length;
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.75,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                    child: Row(
                      children: [
                        Icon(Icons.lock_outline,
                            size: 20, color: theme.colorScheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('AI 请求修改数据',
                              style: theme.textTheme.titleMedium),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '以下操作需要你确认后才会真正执行；'
                        '带 ✏️ 的草稿可点开修改，取消勾选的将被跳过。',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: items.length,
                      itemBuilder: (BuildContext ctx, int index) {
                        final AiWriteConfirmItem item = items[index];
                        return CheckboxListTile(
                          value: selected[index],
                          onChanged: (bool? v) => setSheetState(
                              () => selected[index] = v ?? false),
                          secondary: item.editable
                              ? IconButton(
                                  tooltip: '编辑这条草稿',
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () async {
                                    final Map<String, dynamic>? edited =
                                        item.tool.name == 'create_course'
                                            ? await _editCourseDraftDialog(
                                                ctx, item.args)
                                            : await _editTaskDraftDialog(
                                                ctx, item.args);
                                    if (edited == null) return;
                                    // 延后一帧再刷新卡片，避免与对话框
                                    // 关闭过渡同帧重建。
                                    WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                      setSheetState(() {
                                        item.args = edited;
                                        item.description =
                                            item.tool.describeQuick!(edited);
                                      });
                                    });
                                  },
                                )
                              : const Icon(Icons.edit_note_outlined),
                          title: Text(
                            item.description,
                            style: theme.textTheme.bodyMedium,
                          ),
                        );
                      },
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(sheetContext)
                              .pop(List<Map<String, dynamic>?>.filled(
                                  items.length, null)),
                          child: const Text('全部跳过'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: selectedCount == 0
                              ? null
                              : () => Navigator.of(sheetContext).pop(
                                  <Map<String, dynamic>?>[
                                    for (int i = 0; i < items.length; i++)
                                      selected[i] ? items[i].args : null,
                                  ]),
                          child: Text('执行选中项（$selectedCount）'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
  return result ??
      List<Map<String, dynamic>?>.filled(items.length, null);
}

/// 草稿编辑对话框（create_task 的核心字段）：返回修改后的完整 args，
/// 取消返回 null。日期/时刻做格式校验，非法时禁用保存。
Future<Map<String, dynamic>?> _editTaskDraftDialog(
  BuildContext context,
  Map<String, dynamic> args,
) async {
  final GlobalKey<FormState> formKey = GlobalKey<FormState>();
  final TextEditingController titleCtl =
      TextEditingController(text: (args['title'] as String?) ?? '');
  final TextEditingController dateCtl =
      TextEditingController(text: (args['due_date'] as String?) ?? '');
  final TextEditingController timeCtl =
      TextEditingController(text: (args['due_time'] as String?) ?? '');
  final TextEditingController remindCtl = TextEditingController(
    text: args['remind_minutes'] is num
        ? (args['remind_minutes'] as num).toString()
        : '',
  );
  String priority = args['priority'] is String
      ? args['priority'] as String
      : 'normal';

  final Map<String, dynamic>? edited = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (BuildContext dialogContext) {
      return AlertDialog(
        title: const Text('编辑这条日程'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: titleCtl,
                decoration: const InputDecoration(
                  labelText: '标题',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                validator: (String? v) =>
                    (v == null || v.trim().isEmpty) ? '标题不能为空' : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: dateCtl,
                decoration: const InputDecoration(
                  labelText: '日期（yyyy-MM-dd）',
                  hintText: '2026-09-08',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.datetime,
                validator: (String? v) =>
                    DateTime.tryParse((v ?? '').trim()) == null
                        ? '格式无效，需 yyyy-MM-dd'
                        : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: timeCtl,
                decoration: const InputDecoration(
                  labelText: '时刻（HH:mm，可留空）',
                  hintText: '15:00',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.datetime,
                validator: (String? v) {
                  final String s = (v ?? '').trim();
                  if (s.isEmpty) return null;
                  return RegExp(r'^\d{1,2}:\d{2}$').hasMatch(s)
                      ? null
                      : '格式无效，需 HH:mm';
                },
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: remindCtl,
                decoration: const InputDecoration(
                  labelText: '提前提醒分钟数（可留空=不提醒，0=准时）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.number,
                validator: (String? v) {
                  final String s = (v ?? '').trim();
                  if (s.isEmpty) return null;
                  final int? n = int.tryParse(s);
                  return (n == null || n < 0) ? '需为非负整数' : null;
                },
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: priority,
                decoration: const InputDecoration(
                  labelText: '优先级',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(
                      value: 'normal', child: Text('普通')),
                  DropdownMenuItem<String>(
                      value: 'important', child: Text('重要')),
                  DropdownMenuItem<String>(
                      value: 'urgent', child: Text('紧急')),
                ],
                onChanged: (String? v) => priority = v ?? 'normal',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final FormState? form = formKey.currentState;
              if (form == null || !form.validate()) return;
              Navigator.of(dialogContext).pop(<String, dynamic>{
                ...args,
                'title': titleCtl.text.trim(),
                'due_date': dateCtl.text.trim(),
                'due_time': timeCtl.text.trim(),
                'priority': priority,
                if (remindCtl.text.trim().isNotEmpty)
                  'remind_minutes': int.parse(remindCtl.text.trim())
                else
                  'remind_minutes': null,
              });
            },
            child: const Text('保存'),
          ),
        ],
      );
    },
  );
  // 注意：这里的 controller 不手动 dispose——对话框 pop 有退场动画，
  // 过早释放会让仍在渲染的文本组件脏调度崩溃；随路由销毁即可（一次性开销）。
  // 编辑后带 null 值的字段要在执行前清掉（如「不提醒」），避免覆盖语义混乱。
  if (edited == null) return null;
  return <String, dynamic>{
    for (final MapEntry<String, dynamic> e in edited.entries)
      if (e.value != null) e.key: e.value,
  };
}

/// 课程草稿编辑对话框（create_course 的核心字段）：返回修改后的完整 args，
/// 取消返回 null。星期/节次/周次做范围校验。
Future<Map<String, dynamic>?> _editCourseDraftDialog(
  BuildContext context,
  Map<String, dynamic> args,
) async {
  final GlobalKey<FormState> formKey = GlobalKey<FormState>();
  final TextEditingController nameCtl =
      TextEditingController(text: (args['name'] as String?) ?? '');
  final TextEditingController locationCtl =
      TextEditingController(text: (args['location'] as String?) ?? '');
  final TextEditingController startPeriodCtl = TextEditingController(
      text: args['start_period'] is num
          ? (args['start_period'] as num).toString()
          : '');
  final TextEditingController endPeriodCtl = TextEditingController(
      text: args['end_period'] is num
          ? (args['end_period'] as num).toString()
          : '');
  final TextEditingController startWeekCtl = TextEditingController(
      text: args['start_week'] is num
          ? (args['start_week'] as num).toString()
          : '1');
  final TextEditingController endWeekCtl = TextEditingController(
      text: args['end_week'] is num
          ? (args['end_week'] as num).toString()
          : '');
  int weekday = args['weekday'] is num ? (args['weekday'] as num).toInt() : 1;

  const List<String> weekdayLabels = <String>[
    '周一', '周二', '周三', '周四', '周五', '周六', '周日',
  ];

  final Map<String, dynamic>? edited = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (BuildContext dialogContext) {
      return AlertDialog(
        title: const Text('编辑这门课程'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: nameCtl,
                  decoration: const InputDecoration(
                    labelText: '课程名',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  validator: (String? v) =>
                      (v == null || v.trim().isEmpty) ? '课程名不能为空' : null,
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  initialValue: weekday,
                  decoration: const InputDecoration(
                    labelText: '上课日',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: <DropdownMenuItem<int>>[
                    for (int i = 1; i <= 7; i++)
                      DropdownMenuItem<int>(
                          value: i, child: Text(weekdayLabels[i - 1])),
                  ],
                  onChanged: (int? v) => weekday = v ?? 1,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: startPeriodCtl,
                        decoration: const InputDecoration(
                          labelText: '起始节次',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        keyboardType: TextInputType.number,
                        validator: (String? v) {
                          final int? n = int.tryParse((v ?? '').trim());
                          return (n == null || n < 1) ? '正整数' : null;
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: endPeriodCtl,
                        decoration: const InputDecoration(
                          labelText: '结束节次',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        keyboardType: TextInputType.number,
                        validator: (String? v) {
                          final int? n = int.tryParse((v ?? '').trim());
                          final int? sp =
                              int.tryParse(startPeriodCtl.text.trim());
                          return (n == null || n < 1 || (sp != null && n < sp))
                              ? '不小于起始节次'
                              : null;
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: locationCtl,
                  decoration: const InputDecoration(
                    labelText: '教室（可留空）',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: startWeekCtl,
                        decoration: const InputDecoration(
                          labelText: '开始周',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        keyboardType: TextInputType.number,
                        validator: (String? v) {
                          final String s = (v ?? '').trim();
                          if (s.isEmpty) return null; // 留空 = 保持原值/缺省
                          final int? n = int.tryParse(s);
                          return (n == null || n < 1) ? '正整数' : null;
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: endWeekCtl,
                        decoration: const InputDecoration(
                          labelText: '结束周（可留空=整学期）',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        keyboardType: TextInputType.number,
                        validator: (String? v) {
                          final String s = (v ?? '').trim();
                          if (s.isEmpty) return null; // 留空 = 整学期
                          final int? n = int.tryParse(s);
                          final int? sw =
                              int.tryParse(startWeekCtl.text.trim());
                          return (n == null || n < 1 || (sw != null && n < sw))
                              ? '不小于开始周'
                              : null;
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final FormState? form = formKey.currentState;
              if (form == null || !form.validate()) return;
              // 周次留空 = 保持缺省语义（execute 里按学期总周数/第1周兜底）。
              final Map<String, dynamic> result = <String, dynamic>{
                ...args,
                'name': nameCtl.text.trim(),
                'weekday': weekday,
                'start_period': int.parse(startPeriodCtl.text.trim()),
                'end_period': int.parse(endPeriodCtl.text.trim()),
                'location': locationCtl.text.trim(),
              };
              final String swText = startWeekCtl.text.trim();
              if (swText.isNotEmpty) {
                result['start_week'] = int.parse(swText);
              }
              final String ewText = endWeekCtl.text.trim();
              if (ewText.isNotEmpty) {
                result['end_week'] = int.parse(ewText);
              }
              Navigator.of(dialogContext).pop(result);
            },
            child: const Text('保存'),
          ),
        ],
      );
    },
  );
  // controller 随对话框路由销毁，不手动 dispose（退场动画期间仍被渲染）。
  return edited;
}
