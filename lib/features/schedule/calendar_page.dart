import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/task.dart';
import '../../routes/app_routes.dart';
import '../../shared/plai_toast.dart';
import '../timetable/format.dart';
import 'schedule_providers.dart';
import 'task_actions.dart';
import 'task_list_tile.dart';
import 'task_rules.dart';

/// 月历视图：每天用圆点标记任务密度与完成状态。
///
/// 「某天有任务」统一用 [taskActiveOn] 判定：todo/scheduled 仅截止当日；
/// daily/span 活跃区间含该天即算有任务。圆点沿用现有简化样式：
/// - 有当天未完成（daily 当天未打卡 / 其余顶层未完成）→ 主题色圆点；
/// - 仅当天已完成 → 灰色圆点。
/// 点击某天弹出当天任务列表（支持快速勾选 / 点击详情 / 左滑删除；daily 行
/// 勾选 = 该天打卡）。
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
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final AsyncValue<List<Task>> tasksAsync = ref.watch(tasksProvider);
    // daily 打卡记录：圆点完成判定 / 弹层勾选用。
    final AsyncValue<Map<int, Set<DateTime>>> doneAsync =
        ref.watch(dailyDoneMapProvider);
    if (!tasksAsync.hasValue || !doneAsync.hasValue) {
      if (tasksAsync.hasError || doneAsync.hasError) {
        return const Center(child: Text('任务加载失败'));
      }
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _weekdayHeader(context),
        Expanded(
          child: _buildGrid(context, tasksAsync.requireValue,
              doneAsync.requireValue),
        ),
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
    BuildContext context,
    List<Task> tasks,
    Map<int, Set<DateTime>> doneMap,
  ) {
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
        // 某天有任务 = taskActiveOn（todo/scheduled 截止日；daily/span 区间日）。
        final List<Task> dayTasks = <Task>[
          for (final Task t in tasks)
            if (taskActiveOn(t, date)) t,
        ]..sort(compareTasks);
        return _DayCell(
          date: date,
          hasTask: dayTasks.isNotEmpty,
          hasIncomplete: dayTasks
              .any((Task t) => !_doneOnDay(t, date, doneMap)),
          onTap: () => _openDayTasks(context, date, dayTasks),
        );
      },
    );
  }

  /// 当天是否视为已完成：daily 看该天打卡记录；其余看顶层 completed。
  bool _doneOnDay(Task t, DateTime day, Map<int, Set<DateTime>> doneMap) {
    if (t.type == TaskType.daily) {
      return isDailyDoneOn(t, day,
          doneDates: doneMap[t.id] ?? const <DateTime>{});
    }
    return t.completed;
  }

  void _openDayTasks(
      BuildContext context, DateTime date, List<Task> tasks) {
    if (tasks.isEmpty) {
      showPlaiToast(context, '${formatMonthDay(date)} 没有任务');
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext context) => _DayTasksSheet(date: date),
    );
  }
}

/// 单日格子：日期 + 任务圆点（区分未完成/已完成）。
class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.hasTask,
    required this.hasIncomplete,
    this.onTap,
  });

  final DateTime date;

  /// 当天是否包含任务（taskActiveOn 判定，含区间覆盖的 daily/span）。
  final bool hasTask;

  /// 当天是否仍有未完成项（daily 当天未打卡也算未完成）。
  final bool hasIncomplete;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DateTime now = DateTime.now();
    final bool isToday = _sameDay(date, now);

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
///
/// 直接 watch [tasksProvider] 与 [dailyDoneMapProvider] 并按该天 [taskActiveOn]
/// 过滤，保证左滑删除 / 勾选后条目随数据刷新从列表移除（否则删除后残留已滑出
/// 条目）。todo/scheduled/span 勾选 = 顶层 completed；daily 勾选 = 该天打卡。
class _DayTasksSheet extends ConsumerWidget {
  const _DayTasksSheet({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Task>? all = ref.watch(tasksProvider).value;
    final Map<int, Set<DateTime>> doneMap =
        ref.watch(dailyDoneMapProvider).value ?? const <int, Set<DateTime>>{};
    final List<Task> dayTasks = <Task>[
      for (final Task t in all ?? const <Task>[])
        if (taskActiveOn(t, date)) t,
    ]..sort(compareTasks);

    bool? checkedOf(Task t) {
      if (t.type != TaskType.daily) return null;
      return isDailyDoneOn(t, date,
          doneDates: doneMap[t.id] ?? const <DateTime>{});
    }

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
              child: dayTasks.isEmpty
                  ? Center(
                      child: Text(
                        '当天任务已清空',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    )
                  : ListView(
                      children: [
                        for (final Task t in dayTasks)
                          TaskListTile(
                            task: t,
                            checkedOverride: checkedOf(t),
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
                            onConfirmDelete: () =>
                                confirmDeleteTask(context, ref, t),
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
      if (task.type == TaskType.daily) {
        // daily：勾选 = 该天打卡（mark/clear 打卡日志）。
        await toggleDailyCompleted(ref, task, date);
      } else {
        await toggleTaskCompleted(ref, task);
      }
    } catch (_) {
      if (context.mounted) {
        showPlaiToast(
          context,
          '操作失败，请稍后重试',
          kind: PlaiToastKind.error,
        );
      }
    }
  }
}
