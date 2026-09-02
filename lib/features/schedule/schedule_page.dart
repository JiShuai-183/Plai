import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/course.dart';
import '../../data/models/period.dart';
import '../../data/models/task.dart';
import '../timetable/color_utils.dart';
import '../timetable/course_block.dart';
import '../timetable/course_status.dart';
import '../timetable/format.dart';
import '../timetable/timetable_providers.dart';
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
///
/// 今日课程区实时化（与课表周视图同一套刷新机制）：
/// - 上完的课（下课整分后）实时移除，正在上的课保留并加「上课中」红点；
/// - 课程条取色与课表一致（[resolveCourseColor]），无色课程显中性灰条；
/// - [_scheduleStatusRefresh] 对准下一次上课/下课跳变精确刷新，每分钟
///   [_statusTimer] 兜底，跨天时失效数据源重拉。
class SchedulePage extends ConsumerStatefulWidget {
  const SchedulePage({super.key});

  @override
  ConsumerState<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends ConsumerState<SchedulePage> {
  /// 每分钟自动刷新（兜底：跨天 / 数据变化等边界定时器覆盖不到的场景）。
  Timer? _statusTimer;

  /// 精确刷新定时器：对准今天最近的下一次课程状态跳变时刻
  /// （见 [_scheduleStatusRefresh]）。
  Timer? _boundaryTimer;

  /// 已对准的跳变边界（HH:mm，秒归零），避免 build 为同一边界重复创建定时器。
  DateTime? _lastBoundary;

  /// 上次 setState 时的日期（跨天检测用，年月日归一）。
  DateTime _lastDay = _dateOnly(DateTime.now());

  @override
  void initState() {
    super.initState();
    _statusTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      final DateTime now = DateTime.now();
      final DateTime day = _dateOnly(now);
      if (day != _lastDay) {
        _lastDay = day;
        // 跨天：todayCoursesProvider 在 provider 内固化当天日期，须失效重拉
        // （todayViewProvider 依赖它，会随之重建）。
        ref.invalidate(todayCoursesProvider);
        ref.invalidate(todayViewProvider);
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _boundaryTimer?.cancel();
    super.dispose();
  }

  /// 对准今天最近的下一次状态跳变时刻：build 中按最新数据算出下一次上课/
  /// 下课边界，用一次性 [Timer] 精确触发 setState（±250ms 余量），触发后的
  /// 重建会再次对准下一次。同一边界在多次 build 间只创建一次定时器；
  /// 今天已无未来跳变（全部上完）时不调度，由每分钟 [_statusTimer] 兜底
  /// 处理跨天等场景。
  void _scheduleStatusRefresh() {
    final DateTime now = DateTime.now();
    // 数据未就绪 / 读取失败（如宿主测试环境数据库不可用）时静默跳过调度，
    // 由每分钟 [_statusTimer] 与数据 provider 重建后触发的 build 重试。
    List<TodayCourse> todayCourses = const <TodayCourse>[];
    List<Period> periods = const <Period>[];
    try {
      todayCourses = ref.read(todayCoursesProvider).value ?? todayCourses;
      periods = ref.read(periodsProvider).value ?? periods;
    } catch (_) {
      todayCourses = const <TodayCourse>[];
      periods = const <Period>[];
    }
    final DateTime? boundary = nextStatusChangeBoundary(
      courses: <Course>[
        for (final TodayCourse t in todayCourses) t.course,
      ],
      periods: periods,
      now: now,
    );
    if (boundary == null) {
      _lastBoundary = null;
      _boundaryTimer?.cancel();
      _boundaryTimer = null;
      return;
    }
    if (boundary == _lastBoundary) return; // 同一边界已调度，不重复创建。
    _lastBoundary = boundary;
    _boundaryTimer?.cancel();
    final Duration delay =
        boundary.difference(now) + const Duration(milliseconds: 250);
    _boundaryTimer = Timer(delay, () {
      if (!mounted) return;
      setState(() {}); // 触发重建 → build 再次 _scheduleStatusRefresh 对准下一次。
    });
  }

  @override
  Widget build(BuildContext context) {
    _scheduleStatusRefresh();
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
      body: _buildBody(context),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openNewTask(context),
        icon: const Icon(Icons.add),
        label: const Text('新建任务'),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final AsyncValue<TodayView> viewAsync = ref.watch(todayViewProvider);
    // 今日课程状态/取色依赖节次表与课表状态色设置；watch 保证数据变化
    // （改课程颜色 / 改节次 / 改状态色设置）时联动重绘。
    final AsyncValue<List<Period>> periodsAsync = ref.watch(periodsProvider);
    final AsyncValue<TimetableStatusSettings> settingsAsync =
        ref.watch(timetableStatusSettingsProvider);
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
        child: _buildList(
          context,
          view,
          now: DateTime.now(),
          settings: settingsAsync.value,
          periods: periodsAsync.value,
        ),
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    TodayView view, {
    required DateTime now,
    required TimetableStatusSettings? settings,
    required List<Period>? periods,
  }) {
    final ThemeData theme = Theme.of(context);
    final DateTime today = _dateOnly(now);

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

    // ---- 今日课程（实时状态）----
    // 已上完（下课整分后，连排课按整门课最后结束节次下课）实时移除；正在上
    // 保留并加红点。统一用 build 内取的这一次 now 判定，不各自取时间。
    // periods/节次缺失时 courseStatusOf 返回 null → 状态不明，按「未上完」
    // 保留显示，颜色走课程自选色分支。
    final List<({TodayCourse item, CourseStatus? status})> remaining =
        <({TodayCourse item, CourseStatus? status})>[];
    for (final TodayCourse item in view.courses) {
      final CourseStatus? status = periods == null
          ? null
          : courseStatusOf(
              course: item.course,
              periods: periods,
              now: now,
              isTodayWeek: true,
            );
      if (status == CourseStatus.finished) continue;
      remaining.add((item: item, status: status));
    }
    final bool allFinished = view.courses.isNotEmpty && remaining.isEmpty;

    children.add(_sectionHeader(context, '今日课程',
        view.courses.isEmpty ? '' : '第 ${view.courses.first.week} 周'));
    if (view.courses.isEmpty) {
      children.add(_emptyHint(context, '今天没有课'));
    } else if (allFinished) {
      children.add(_emptyHint(context, '今日课程已结束'));
    } else {
      for (final ({TodayCourse item, CourseStatus? status}) entry in remaining) {
        children.add(_CourseTile(
          item: entry.item,
          color: _courseBarColor(theme, entry.item, entry.status, settings),
          ongoing: entry.status == CourseStatus.ongoing,
        ));
      }
    }

    // ---- 任务区 ----
    children.add(_sectionHeader(context, '任务', ''));
    if (overdue.isEmpty && todayTasks.isEmpty && done.isEmpty) {
      children.add(_emptyHint(context, '今天没有任务，放松一下吧'));
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

  /// 课程条颜色：完全复用课表取色逻辑（[resolveCourseColor]），无色课程显
  /// 中性（浅灰条，不再 fallback 主题色）。状态色总开关开着时按
  /// 状态（未上/正在上）取状态色。
  Color _courseBarColor(
    ThemeData theme,
    TodayCourse item,
    CourseStatus? status,
    TimetableStatusSettings? settings,
  ) {
    final Course c = item.course;
    // settings 尚未加载（首帧）时退化为课程自选色 / 中性，不做状态色。
    final Color? color = settings == null
        ? (c.color.trim().isEmpty ? null : colorFromHex(c.color))
        : resolveCourseColor(course: c, status: status, settings: settings);
    return color ?? theme.colorScheme.outlineVariant;
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

  Widget _emptyHint(BuildContext context, String text) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Text(text, style: theme.textTheme.bodyMedium),
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
///
/// [color] 已由父级按课表取色逻辑解析完成（无色 → 中性灰）；[ongoing] 为
/// true 时在 subtitle 前缀加「● 上课中」红点（error 色）。
class _CourseTile extends StatelessWidget {
  const _CourseTile({
    required this.item,
    required this.color,
    required this.ongoing,
  });

  final TodayCourse item;
  final Color color;
  final bool ongoing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Course c = item.course;

    final String periodText = c.startPeriod == c.endPeriod
        ? '第 ${c.startPeriod} 节'
        : '第 ${c.startPeriod}-${c.endPeriod} 节';
    final String timeText = _timeRange();
    final String location = c.location.isEmpty ? '' : ' · ${c.location}';
    final Color error = theme.colorScheme.error;

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
        subtitle: Text.rich(
          TextSpan(
            style: theme.textTheme.bodySmall,
            children: <InlineSpan>[
              if (ongoing) ...<InlineSpan>[
                TextSpan(
                  text: '● ',
                  style: TextStyle(color: error),
                ),
                TextSpan(
                  text: '上课中  ',
                  style: TextStyle(
                    color: error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              TextSpan(text: '$periodText$location$timeText'),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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
