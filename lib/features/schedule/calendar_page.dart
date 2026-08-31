import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/task.dart';
import '../../routes/app_routes.dart';
import '../timetable/format.dart';
import 'schedule_providers.dart';
import 'task_actions.dart';
import 'task_list_tile.dart';
import 'task_rules.dart';

/// 月历视图：每天用圆点标记任务密度与完成状态。
///
/// - 有未完成任务 → 主题色圆点；
/// - 仅已完成任务 → 灰色圆点。
/// 点击某天弹出当天任务列表（支持快速勾选 / 点击详情 / 左滑删除）。
class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({super.key});

  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<CalendarPage> {
  late DateTime _month;

  @override
  void initState() {
    super.initState();
    final DateTime now = DateTime.now();
    _month = DateTime(now.year, now.month, 1);
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Task>> tasksAsync = ref.watch(tasksProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text('${_month.year}年${_month.month}月'),
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: '上一月',
            onPressed: () => setState(() {
              _month = DateTime(_month.year, _month.month - 1, 1);
            }),
          ),
          TextButton(
            onPressed: () => setState(() {
              final DateTime now = DateTime.now();
              _month = DateTime(now.year, now.month, 1);
            }),
            child: const Text('今天'),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: '下一月',
            onPressed: () => setState(() {
              _month = DateTime(_month.year, _month.month + 1, 1);
            }),
          ),
        ],
      ),
      body: tasksAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('任务加载失败')),
        data: (tasks) => _buildBody(context, tasks),
      ),
    );
  }

  Widget _buildBody(BuildContext context, List<Task> tasks) {
    final Map<DateTime, List<Task>> byDate = <DateTime, List<Task>>{};
    for (final Task t in tasks) {
      final DateTime day = _dateOnly(t.dueDate);
      byDate.putIfAbsent(day, () => <Task>[]).add(t);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _weekdayHeader(context),
        Expanded(child: _buildGrid(context, byDate)),
      ],
    );
  }

  Widget _weekdayHeader(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    const List<String> labels = ['一', '二', '三', '四', '五', '六', '日'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          for (final String label in labels)
            Expanded(
              child: Center(
                child: Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildGrid(
      BuildContext context, Map<DateTime, List<Task>> byDate) {
    final int leading = _month.weekday - 1; // 周一为列首
    final int daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final int cellCount = ((leading + daysInMonth + 6) ~/ 7) * 7;

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        childAspectRatio: 0.82,
      ),
      itemCount: cellCount,
      itemBuilder: (BuildContext context, int index) {
        if (index < leading) return const SizedBox.shrink();
        final int day = index - leading + 1;
        if (day > daysInMonth) return const SizedBox.shrink();
        final DateTime date = DateTime(_month.year, _month.month, day);
        final List<Task> dayTasks = byDate[date] ?? const <Task>[];
        return _DayCell(
          date: date,
          tasks: dayTasks,
          onTap: () => _openDayTasks(context, date, dayTasks),
        );
      },
    );
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  void _openDayTasks(
      BuildContext context, DateTime date, List<Task> tasks) {
    if (tasks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${formatMonthDay(date)} 没有任务')),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext context) => _DayTasksSheet(date: date, tasks: tasks),
    );
  }
}

/// 单日格子：日期 + 任务圆点（区分未完成/已完成）。
class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.tasks,
    this.onTap,
  });

  final DateTime date;
  final List<Task> tasks;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DateTime now = DateTime.now();
    final bool isToday = _sameDay(date, now);
    final bool hasIncomplete = tasks.any((Task t) => !t.completed);
    final bool hasTask = tasks.isNotEmpty;

    final Color dotColor = !hasTask
        ? Colors.transparent
        : hasIncomplete
            ? theme.colorScheme.primary
            : theme.colorScheme.outline;

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: isToday
                ? BoxDecoration(
                    color: theme.colorScheme.primary,
                    shape: BoxShape.circle,
                  )
                : null,
            child: Text(
              '${date.day}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                color: isToday
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
        ],
      ),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// 某天任务列表（底部弹层）：快速勾选 / 点击详情 / 左滑删除。
class _DayTasksSheet extends ConsumerWidget {
  const _DayTasksSheet({required this.date, required this.tasks});

  final DateTime date;
  final List<Task> tasks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Task> sorted = tasks.toList()..sort(compareTasks);
    return SafeArea(
      child: FractionallySizedBox(
        heightFactor: 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '${formatDateWeekday(date)} 的任务',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                children: [
                  for (final Task t in sorted)
                    TaskListTile(
                      task: t,
                      onToggle: () => _toggle(context, ref, t),
                      onTap: () {
                        // 先拿到 Navigator 再关闭底部弹层，避免使用已卸载的 context。
                        final NavigatorState navigator = Navigator.of(context);
                        navigator.pop();
                        if (t.id != null) {
                          navigator.pushNamed(AppRoutes.taskDetail,
                              arguments: t.id);
                        }
                      },
                      onDelete: () => _delete(context, ref, t),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref, Task task) async {
    try {
      await toggleTaskCompleted(ref, task);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('操作失败，请稍后重试')),
        );
      }
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Task task) async {
    await confirmDeleteTask(context, ref, task);
  }
}
