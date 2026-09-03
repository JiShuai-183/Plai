import 'package:flutter/material.dart';

import '../../data/models/task.dart';
import '../timetable/format.dart';
import 'task_rules.dart';

/// 任务列表项：勾选打卡 + 优先级标签 + 日期时刻 + 逾期标红 + 左滑删除。
///
/// 今日视图 / 任务列表页 / 日历某天共用。
class TaskListTile extends StatelessWidget {
  const TaskListTile({
    super.key,
    required this.task,
    this.onToggle,
    this.onTap,
    this.onConfirmDelete,
  });

  final Task task;

  /// 勾选 / 取消打卡回调。
  final VoidCallback? onToggle;

  /// 点击进入详情。
  final VoidCallback? onTap;

  /// 左滑删除「确认」回调；为 null 时不启用滑动删除。
  ///
  /// 在 Dismissible 真正滑出前调用（confirmDismiss），实现方负责：弹确认框
  /// → 确认后执行删除并 `await` 列表数据源刷新完成 → 返回 true（条目已从
  /// 数据/重建树移除，放行滑出）；用户取消或删除失败 → 返回 false（Dismissible
  /// 自动弹回原位）。不负责 onDismissed（删除已前置完成）。
  final Future<bool> Function()? onConfirmDelete;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool completed = task.completed;
    final bool overdue = !completed && isTaskOverdue(task);
    final Color textColor =
        completed ? theme.colorScheme.outline : theme.colorScheme.onSurface;

    final Widget tile = ListTile(
      contentPadding: const EdgeInsets.only(left: 8, right: 8),
      leading: Checkbox(
        value: completed,
        onChanged: onToggle == null ? null : (_) => onToggle!(),
      ),
      title: Text(
        task.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: overdue ? theme.colorScheme.error : textColor,
          decoration: completed ? TextDecoration.lineThrough : null,
        ),
      ),
      subtitle: _buildSubtitle(theme, overdue),
      onTap: onTap,
    );

    if (onConfirmDelete == null) return tile;
    return Dismissible(
      key: ValueKey('task-${task.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: theme.colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: Icon(Icons.delete_outline, color: theme.colorScheme.error),
      ),
      // 在真正滑出前拦截：确认并删完（等列表刷新移除条目）才放行；取消则
      // false → Dismissible 弹回原位。删除在 confirmDismiss 内前置完成，故
      // 不再需要 onDismissed。
      confirmDismiss: (_) async {
        final Future<bool> Function()? confirm = onConfirmDelete;
        if (confirm == null) return false;
        return await confirm();
      },
      child: tile,
    );
  }

  Widget _buildSubtitle(ThemeData theme, bool overdue) {
    final List<Widget> items = <Widget>[];

    // 类型。
    items.add(Text(task.type.label, style: theme.textTheme.bodySmall));
    items.add(const SizedBox(width: 8));

    // 优先级标签。
    items.add(_buildTag(
      theme,
      text: task.priority.label,
      foreground: _priorityForeground(theme, task.priority),
      background: _priorityBackground(theme, task.priority),
    ));

    // 日期时刻。
    final String time = task.dueTime ?? '';
    final String dateText = formatMonthDay(task.dueDate);
    items.add(Text(
      time.isEmpty ? dateText : '$dateText $time',
      style: theme.textTheme.bodySmall,
    ));

    // 逾期标红。
    if (overdue) {
      items.add(Text(
        '已逾期',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.error),
      ));
    }

    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: items,
    );
  }

  Widget _buildTag(
    ThemeData theme, {
    required String text,
    required Color foreground,
    required Color background,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }

  Color _priorityForeground(ThemeData theme, Priority priority) {
    switch (priority) {
      case Priority.urgent:
        return theme.colorScheme.error;
      case Priority.important:
        return theme.colorScheme.onTertiaryContainer;
      case Priority.normal:
        return theme.colorScheme.onSurfaceVariant;
    }
  }

  Color _priorityBackground(ThemeData theme, Priority priority) {
    switch (priority) {
      case Priority.urgent:
        return theme.colorScheme.errorContainer;
      case Priority.important:
        return theme.colorScheme.tertiaryContainer;
      case Priority.normal:
        return theme.colorScheme.surfaceContainerHighest;
    }
  }
}
