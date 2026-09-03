import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/task.dart';
import '../timetable/format.dart';
import 'schedule_providers.dart';
import 'task_actions.dart';
import 'task_form_page.dart';
import 'task_list_tile.dart';
import 'task_rules.dart';

/// 全部任务页：按日期分组，优先级排序，逾期未完成标红置顶。
///
/// 顶部提供类型（全部/待办/定点日程）与状态（全部/未完成/已完成）筛选。
class TaskListPage extends ConsumerStatefulWidget {
  const TaskListPage({super.key});

  @override
  ConsumerState<TaskListPage> createState() => _TaskListPageState();
}

class _TaskListPageState extends ConsumerState<TaskListPage> {
  /// null=全部类型。
  TaskType? _typeFilter;

  /// null=全部状态；false=未完成；true=已完成。
  bool? _completedFilter;

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Task>> tasksAsync = ref.watch(tasksProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('全部任务')),
      body: tasksAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('任务加载失败')),
        data: (List<Task> tasks) => _buildBody(context, tasks),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const TaskFormPage()),
        ),
        icon: const Icon(Icons.add),
        label: const Text('新建任务'),
      ),
    );
  }

  Widget _buildBody(BuildContext context, List<Task> allTasks) {
    final List<Task> filtered = allTasks
        .where((Task t) =>
            (_typeFilter == null || t.type == _typeFilter) &&
            (_completedFilter == null || t.completed == _completedFilter))
        .toList();

    final List<Task> overdue = filtered
        .where((Task t) => isTaskOverdue(t))
        .toList()
      ..sort(compareTasks);
    final List<Task> others = filtered
        .where((Task t) => !isTaskOverdue(t))
        .toList()
      ..sort(compareTasks);

    // 分组键用 dateSortKey（daily 按开始日、span/todo/scheduled 按截止日），
    // 与 compareTasks 排序同源，跨期任务归位其自然日。
    final List<(DateTime, List<Task>)> sections = <(DateTime, List<Task>)>[];
    for (final Task t in others) {
      final DateTime day = dateSortKey(t);
      if (sections.isEmpty || sections.last.$1 != day) {
        sections.add((day, <Task>[]));
      }
      sections.last.$2.add(t);
    }

    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildFilters(context),
        const Divider(height: 1),
        Expanded(
          child: filtered.isEmpty
              ? _emptyView(context)
              : ListView(
                  padding: const EdgeInsets.only(bottom: 88),
                  children: [
                    if (overdue.isNotEmpty) ...[
                      _groupHeader(context, '已逾期', error: true),
                      for (final Task t in overdue)
                        _tile(context, t),
                    ],
                    for (final (DateTime day, List<Task> group) in sections) ...[
                      _groupHeader(context, _dayLabel(day, today), error: false),
                      for (final Task t in group) _tile(context, t),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildFilters(BuildContext context) {
    Widget buildChip(String label, bool selected, VoidCallback onTap) {
      return ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              buildChip('全部', _typeFilter == null,
                  () => setState(() => _typeFilter = null)),
              buildChip(TaskType.todo.label, _typeFilter == TaskType.todo,
                  () => setState(() => _typeFilter = TaskType.todo)),
              buildChip(TaskType.scheduled.label,
                  _typeFilter == TaskType.scheduled,
                  () => setState(() => _typeFilter = TaskType.scheduled)),
              buildChip(TaskType.daily.label, _typeFilter == TaskType.daily,
                  () => setState(() => _typeFilter = TaskType.daily)),
              buildChip(TaskType.span.label, _typeFilter == TaskType.span,
                  () => setState(() => _typeFilter = TaskType.span)),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              buildChip('全部状态', _completedFilter == null,
                  () => setState(() => _completedFilter = null)),
              buildChip('未完成', _completedFilter == false,
                  () => setState(() => _completedFilter = false)),
              buildChip('已完成', _completedFilter == true,
                  () => setState(() => _completedFilter = true)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _groupHeader(BuildContext context, String title,
      {required bool error}) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: error
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  String _dayLabel(DateTime day, DateTime today) {
    final String base = formatDateWeekday(day);
    if (day == today) return '$base · 今天';
    final DateTime yesterday = today.subtract(const Duration(days: 1));
    if (day == yesterday) return '$base · 昨天';
    return base;
  }

  Widget _tile(BuildContext context, Task task) {
    final bool isDaily = task.type == TaskType.daily;
    return TaskListTile(
      task: task,
      // daily 无"某天"勾选语义：列表页不显示勾选框（点击进详情）；其余类型
      // 顶层 completed 勾选整体完成。
      showCheckbox: !isDaily,
      onToggle: isDaily ? null : () => _toggle(context, task),
      onTap: () => openTaskDetail(context, task),
      onConfirmDelete: () => confirmDeleteTask(context, ref, task),
    );
  }

  Future<void> _toggle(BuildContext context, Task task) async {
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

  Widget _emptyView(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.task_alt_outlined,
              size: 56, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text('没有符合条件的任务', style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
