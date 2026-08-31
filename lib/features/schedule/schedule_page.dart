import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/course.dart';
import '../../data/models/task.dart';
import '../timetable/color_utils.dart';
import '../timetable/format.dart';
import 'calendar_page.dart';
import 'schedule_providers.dart';
import 'task_actions.dart';
import 'task_form_page.dart';
import 'task_list_page.dart';
import 'task_list_tile.dart';
import 'task_rules.dart';

/// 今日页（Tab 内容，承载在 [AppShell] 的 IndexedStack 中，不 push 成新路由）。
///
/// 上半部分今日课程（读课表模块数据 + 周次规则过滤），下半部分任务区：
/// 已逾期（标红置顶）→ 今日待办与到期定点日程 → 今日已完成。
class SchedulePage extends ConsumerWidget {
  const SchedulePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('今日'),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_month_outlined),
            tooltip: '日历',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const CalendarPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.list_alt_outlined),
            tooltip: '全部任务',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const TaskListPage()),
            ),
          ),
        ],
      ),
      body: _buildBody(context, ref),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openNewTask(context),
        icon: const Icon(Icons.add),
        label: const Text('新建任务'),
      ),
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref) {
    final AsyncValue<TodayView> viewAsync = ref.watch(todayViewProvider);
    return viewAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => const Center(child: Text('数据加载失败')),
      data: (TodayView view) => RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(todayViewProvider);
          try {
            await ref.read(todayViewProvider.future);
          } catch (_) {
            // 刷新失败静默，页面保持当前内容。
          }
        },
        child: _buildList(context, ref, view),
      ),
    );
  }

  Widget _buildList(BuildContext context, WidgetRef ref, TodayView view) {
    final ThemeData theme = Theme.of(context);
    final DateTime today = _dateOnly(DateTime.now());

    final List<Task> overdue = view.tasks
        .where((Task t) => isTaskOverdue(t))
        .toList()
      ..sort(compareTasks);
    final List<Task> todayTasks = view.tasks
        .where((Task t) =>
            !t.completed && _sameDay(t.dueDate, today))
        .toList()
      ..sort(compareTasks);
    final List<Task> done = view.tasks
        .where((Task t) => t.completed && _sameDay(t.dueDate, today))
        .toList()
      ..sort(compareTasks);

    final List<Widget> children = <Widget>[];

    // ---- 今日课程 ----
    children.add(_sectionHeader(context, '今日课程', view.courses.isEmpty ? '' : '第 ${view.courses.first.week} 周'));
    if (view.courses.isEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Text('今天没有课', style: theme.textTheme.bodyMedium),
      ));
    } else {
      for (final TodayCourse item in view.courses) {
        children.add(_CourseTile(item: item));
      }
    }

    // ---- 任务区 ----
    children.add(_sectionHeader(context, '任务', ''));
    if (overdue.isEmpty && todayTasks.isEmpty && done.isEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Text('今天没有任务，放松一下吧', style: theme.textTheme.bodyMedium),
      ));
    }

    if (overdue.isNotEmpty) {
      children.add(_groupHeader(context, '已逾期', error: true));
      for (final Task t in overdue) {
        children.add(_tile(context, ref, t));
      }
    }
    if (todayTasks.isNotEmpty) {
      children.add(_groupHeader(context, '今日', error: false));
      for (final Task t in todayTasks) {
        children.add(_tile(context, ref, t));
      }
    }
    if (done.isNotEmpty) {
      children.add(_groupHeader(context, '已完成', error: false));
      for (final Task t in done) {
        children.add(_tile(context, ref, t));
      }
    }
    children.add(const SizedBox(height: 88));

    return ListView(
      padding: const EdgeInsets.only(top: 4),
      children: children,
    );
  }

  Widget _sectionHeader(BuildContext context, String title, String trailing) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: theme.textTheme.titleMedium),
          ),
          if (trailing.isNotEmpty)
            Text(trailing, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _groupHeader(BuildContext context, String title,
      {required bool error}) {
    final ThemeData theme = Theme.of(context);
    final Color color =
        error ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(color: color),
      ),
    );
  }

  Widget _tile(BuildContext context, WidgetRef ref, Task task) {
    return TaskListTile(
      task: task,
      onToggle: () => _toggle(context, ref, task),
      onTap: () => openTaskDetail(context, task),
      onDelete: () => confirmDeleteTask(context, ref, task),
    );
  }

  Future<void> _toggle(
      BuildContext context, WidgetRef ref, Task task) async {
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

  Future<void> _openNewTask(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const TaskFormPage()),
    );
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// 今日课程卡片：课程色条 + 名称 + 节次/地点/时刻。
class _CourseTile extends StatelessWidget {
  const _CourseTile({required this.item});

  final TodayCourse item;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Course c = item.course;
    final Color color =
        c.color.isNotEmpty ? colorFromHex(c.color) : theme.colorScheme.primary;

    final String periodText = c.startPeriod == c.endPeriod
        ? '第 ${c.startPeriod} 节'
        : '第 ${c.startPeriod}-${c.endPeriod} 节';
    final String timeText = _timeRange();
    final String location = c.location.isEmpty ? '' : ' · ${c.location}';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: Container(
          width: 6,
          height: 40,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '$periodText$location$timeText',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
      ),
    );
  }

  String _timeRange() {
    final TimeOfDay? start = item.startTime;
    final TimeOfDay? end = item.endTime;
    if (start == null && end == null) return '';
    final String s = start == null ? '--:--' : formatTimeOfDay(start);
    final String e = end == null ? '--:--' : formatTimeOfDay(end);
    return ' · $s-$e';
  }
}
