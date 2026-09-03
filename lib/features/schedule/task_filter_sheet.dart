import 'package:flutter/material.dart';

import '../../data/models/task.dart';
import 'task_list_page.dart';

/// 任务筛选组合状态：类型多选 + 完成状态三态。
class TaskFilterSelection {
  const TaskFilterSelection({required this.types, this.completion});

  /// 已选任务类型（4 类全选 = 不限类型）。
  final Set<TaskType> types;

  /// 完成状态：null=全部；false=未完成；true=已完成。
  final bool? completion;

  /// 是否完全未过滤（类型全选且完成状态为全部）。
  bool get isDefault => types.length == TaskType.values.length && completion == null;
}

/// 弹出任务筛选底部面板。
///
/// 勾选即时回调 [onChanged]（传最新 [TaskFilterSelection]），父级（今日页）
/// 据此实时重渲染任务区；面板自身关闭不返回结果。面板内含「查看全部任务」
/// 入口（push [TaskListPage]）。
Future<void> showTaskFilterSheet(
  BuildContext context, {
  required TaskFilterSelection current,
  required ValueChanged<TaskFilterSelection> onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => TaskFilterSheet(current: current, onChanged: onChanged),
  );
}

/// 常用筛选 UI：任务类型多选 + 完成状态三态 + 查看全部任务入口。
class TaskFilterSheet extends StatefulWidget {
  const TaskFilterSheet({
    super.key,
    required this.current,
    required this.onChanged,
  });

  /// 进入面板时的筛选状态。
  final TaskFilterSelection current;

  /// 任一次勾选变化即回调（传最新全量选中集）。
  final ValueChanged<TaskFilterSelection> onChanged;

  @override
  State<TaskFilterSheet> createState() => _TaskFilterSheetState();
}

class _TaskFilterSheetState extends State<TaskFilterSheet> {
  /// 面板内展示顺序（与 PRD 常用排序一致）：待办 / 定点 / 每日打卡 / 跨期。
  static const List<TaskType> _typeOrder = <TaskType>[
    TaskType.todo,
    TaskType.scheduled,
    TaskType.daily,
    TaskType.span,
  ];

  late Set<TaskType> _types = Set<TaskType>.of(widget.current.types);
  late bool? _completion = widget.current.completion;

  void _apply() {
    widget.onChanged(
      TaskFilterSelection(types: _types, completion: _completion),
    );
  }

  void _setStateApply(VoidCallback change) {
    setState(change);
    _apply();
  }

  void _toggleType(TaskType type, bool selected) {
    _setStateApply(() {
      if (selected) {
        _types.add(type);
      } else {
        _types.remove(type);
      }
    });
  }

  /// 「显示全部」：类型全选 + 完成状态回到「全部」。
  void _resetAll() {
    _setStateApply(() {
      _types = TaskType.values.toSet();
      _completion = null;
    });
  }

  void _openAllTasks(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const TaskListPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // 标题行 + 「显示全部」快捷项。
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 8, 0),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '常用筛选',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  TextButton(
                    onPressed: widget.current.isDefault
                        ? null
                        : _resetAll,
                    child: const Text('显示全部'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                '任务类型',
                style: theme.textTheme.labelLarge
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            for (final TaskType type in _typeOrder)
              CheckboxListTile(
                value: _types.contains(type),
                onChanged: (bool? checked) =>
                    _toggleType(type, checked ?? false),
                title: Text(type.label),
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                '完成状态',
                style: theme.textTheme.labelLarge
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: _buildCompletionChips(theme),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.list_alt_outlined),
              title: const Text('查看全部任务'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openAllTasks(context),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildCompletionChips(ThemeData theme) {
    Widget chip(String label, bool? value) {
      final bool selected = _completion == value;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) => _setStateApply(() => _completion = value),
          visualDensity: VisualDensity.compact,
        ),
      );
    }

    return Row(
      children: <Widget>[
        chip('全部', null),
        chip('未完成', false),
        chip('已完成', true),
      ],
    );
  }
}
