import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../data/models/task.dart';
import '../timetable/format.dart';
import 'task_rules.dart';

/// 任务列表项：勾选打卡 + 优先级标签 + 日期时刻 + 逾期标红 + 左滑删除。
///
/// 左滑交互（自绘，非 Dismissible，可限位、不整条滑出屏）：
/// - 最多左滑露出 tile 宽 1/3，拖到此即顶住（clamp，无弹性）；
/// - **松手**才触发：左滑位移 ≥ 阈值（宽 1/6，至少 56px）→ fire-and-forget
///   触发 [onConfirmDelete]（其内部弹确认框；确认后删数据并等列表数据源刷新
///   使条目出树；取消则保留），并回弹原位（~180ms）；滑不足仅回弹不触发；
/// - 右滑 / 往回拖到 0 不触发，仅复位；
/// - [onConfirmDelete] 为 null 时不启用滑动（纯 ListTile，无手势/无背景）。
///
/// 今日视图 / 任务列表页 / 日历某天共用。
class TaskListTile extends StatefulWidget {
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

  /// 左滑触发删除确认回调（松手到位后 fire-and-forget 调用，不 await）。
  /// 实现方负责：弹确认框 → 确认后执行删除并 `await` 列表数据源刷新使条目随
  /// 重建从列表移除；取消则条目保留。条目不回滑出屏外，靠数据刷新移除。
  final Future<bool> Function()? onConfirmDelete;

  @override
  State<TaskListTile> createState() => _TaskListTileState();
}

class _TaskListTileState extends State<TaskListTile>
    with SingleTickerProviderStateMixin {
  /// 左滑最大露出位移比例：tile 宽 1/3（到顶即止，不继续左滑）。
  static const double _slideRatio = 1 / 3;

  /// 触发删除确认的最小位移阈值（绝对值下限），小屏也能滑到位。
  static const double _triggerMin = 56.0;

  /// 回弹时长。
  static const Duration _settleDuration = Duration(milliseconds: 180);

  /// 本次 build 测得的可滑上限（tile 宽 1/3）。
  double _dragLimit = 0;

  /// 当前左滑位移（px，≥0；0=原位）。放 Notifier 里跟手更新，避免整树重建。
  final ValueNotifier<double> _offset = ValueNotifier<double>(0);

  /// 松手回弹控制器。
  late final AnimationController _settle;
  late final CurvedAnimation _settleCurve;

  /// 本次回弹起始位移。
  double _settleFrom = 0;

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(vsync: this, duration: _settleDuration);
    _settleCurve = CurvedAnimation(parent: _settle, curve: Curves.easeOutCubic);
    _settle.addListener(
      () => _offset.value = _settleFrom * (1 - _settleCurve.value),
    );
  }

  @override
  void dispose() {
    _settle.dispose();
    _offset.dispose();
    super.dispose();
  }

  /// 松手触发阈值 = tile 宽 1/6（限位的 1/2），且不小于 [_triggerMin]；
  /// 不大于限位（超窄 tile 时全滑即可触发）。
  double _triggerThreshold() {
    final double byRatio = _dragLimit / 2; // 限位=_dragLimit=宽1/3 → 此=宽1/6
    return math.min(math.max(byRatio, _triggerMin), _dragLimit);
  }

  void _onDragStart(DragStartDetails details) {
    _settle.stop(); // 拖动打断回弹，从当前位移继续跟手。
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final double next = _offset.value - details.delta.dx; // 左滑(dx<0)→增大
    _offset.value = next.clamp(0.0, _dragLimit);
  }

  void _onDragEnd(DragEndDetails details) {
    final double off = _offset.value;
    if (off >= _triggerThreshold()) {
      // 左滑到位才触发：fire-and-forget，确认框由其内部弹出。
      final Future<bool> Function()? confirm = widget.onConfirmDelete;
      if (confirm != null) unawaited(confirm());
    }
    if (_offset.value > 0) {
      _settleFrom = _offset.value;
      _settle.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Task task = widget.task;
    final bool completed = task.completed;
    final bool overdue = !completed && isTaskOverdue(task);
    final Color textColor =
        completed ? theme.colorScheme.outline : theme.colorScheme.onSurface;

    final Widget tile = ListTile(
      contentPadding: const EdgeInsets.only(left: 8, right: 8),
      leading: Checkbox(
        value: completed,
        onChanged: widget.onToggle == null ? null : (_) => widget.onToggle!(),
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
      onTap: widget.onTap,
    );

    if (widget.onConfirmDelete == null) return tile;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _dragLimit = math.max(0.0, constraints.maxWidth * _slideRatio);
        final double limit = _dragLimit;
        return ValueListenableBuilder<double>(
          valueListenable: _offset,
          builder: (BuildContext context, double value, Widget? child) {
            final double offset = value.clamp(0.0, limit);
            return Stack(
              children: <Widget>[
                // 删除背景：只占 content 移开后露出的右侧条带（width=offset），
                // 不会透过仍被 content 覆盖的区域露出。
                if (offset > 0)
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    width: offset,
                    child: Container(
                      color: theme.colorScheme.errorContainer,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      child: Icon(
                        Icons.delete_outline,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                Transform.translate(
                  offset: Offset(-offset, 0),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    dragStartBehavior: DragStartBehavior.down,
                    onHorizontalDragStart: _onDragStart,
                    onHorizontalDragUpdate: _onDragUpdate,
                    onHorizontalDragEnd: _onDragEnd,
                    child: tile,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildSubtitle(ThemeData theme, bool overdue) {
    final Task task = widget.task;
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
