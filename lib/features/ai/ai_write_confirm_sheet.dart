import 'package:flutter/material.dart';

import 'ai_write_tools.dart';

/// 待确认的写操作条目（S8 草稿卡）。
///
/// - [tool]/[args]：发起时的写调用（[args] 可被草稿编辑替换）；
/// - [description]：人类可读文案（编辑保存后经 tool.describeQuick 重算）；
/// - [editable]：是否开放草稿编辑（需工具支持 describeQuick，如 create_task）。
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
            (tool.name == 'create_task' || tool.name == 'update_task');

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
                                        await _editDraftDialog(
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
Future<Map<String, dynamic>?> _editDraftDialog(
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
