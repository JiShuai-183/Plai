import 'package:flutter/material.dart';

import '../../data/models/task.dart';
import 'task_list_page.dart';

/// 弹出任务类型筛选底部面板。
///
/// 勾选即时回调 [onChanged]，父级（今日页）据此实时重渲染任务区；面板自身
/// 关闭不返回结果。面板内含「查看全部任务」入口（push [TaskListPage]）。
Future<void> showTaskFilterSheet(
  BuildContext context, {
  required Set<TaskType> current,
  required ValueChanged<Set<TaskType>> onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => TaskFilterSheet(initial: current, onChanged: onChanged),
  );
}

/// 常用筛选 UI：任务类型多选 + 查看全部任务入口。
class TaskFilterSheet extends StatefulWidget {
  const TaskFilterSheet({
    super.key,
    required this.initial,
    required this.onChanged,
  });

  /// 进入面板时的已选类型。
  final Set<TaskType> initial;

  /// 任一次勾选变化即回调（传最新全量选中集）。
  final ValueChanged<Set<TaskType>> onChanged;

  @override
  State<TaskFilterSheet> createState() => _TaskFilterSheetState();
}

class _TaskFilterSheetState extends State<TaskFilterSheet> {
  /// 面板内展示顺序（与 PRD 常用排序一致）：待办 / 定点 / 每日打卡 / 跨期。
  static const List<TaskType> _order = <TaskType>[
    TaskType.todo,
    TaskType.scheduled,
    TaskType.daily,
    TaskType.span,
  ];

  late Set<TaskType> _selection = Set<TaskType>.of(widget.initial);

  bool get _allSelected => _selection.length == TaskType.values.length;

  void _apply(Set<TaskType> next) {
    setState(() => _selection = Set<TaskType>.of(next));
    widget.onChanged(_selection);
  }

  void _toggle(TaskType type, bool selected) {
    final Set<TaskType> next = Set<TaskType>.of(_selection);
    if (selected) {
      next.add(type);
    } else {
      next.remove(type);
    }
    _apply(next);
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
          children: <Widget>[
            // 标题行 + 「显示全部」快捷项。
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 8, 0),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '任务类型',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  TextButton(
                    onPressed:
                        _allSelected ? null : () => _apply(TaskType.values.toSet()),
                    child: const Text('显示全部'),
                  ),
                ],
              ),
            ),
            for (final TaskType type in _order)
              CheckboxListTile(
                value: _selection.contains(type),
                onChanged: (bool? checked) =>
                    _toggle(type, checked ?? false),
                title: Text(type.label),
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
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
}
