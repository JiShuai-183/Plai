import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/course.dart';
import '../../data/models/holiday.dart';
import '../../data/models/period.dart';
import '../../data/models/semester.dart';
import 'class_lanes.dart';
import 'course_block.dart';
import 'course_form_page.dart';
import 'course_status.dart';
import 'day_view_page.dart';
import 'format.dart';
import 'timetable_providers.dart';
import 'week_rules.dart';

/// 周视图：周一为起始，纵向节次 × 横向星期。
///
/// 自带周次切换（左右滑动/箭头/「回到本周」）、今天高亮、课程块按课程
/// 颜色渲染、同时间并排（[computeCourseSlots]）。停课周次课程不展示。
class WeekView extends ConsumerStatefulWidget {
  const WeekView({super.key, required this.semester, this.initialWeek});

  /// 要展示的学期（非空）。
  final Semester semester;

  /// 初始定位周次；null 时定位到当前周（用于深链）。
  final int? initialWeek;

  @override
  ConsumerState<WeekView> createState() => _WeekViewState();
}

class _WeekViewState extends ConsumerState<WeekView> {
  static const double _timeColWidth = 46;
  static const double _headerHeight = 46;
  static const double _rowHeight = 56;

  late WeekRules _rules;
  late int _week;

  /// 周条是否收起（收起后仅显示「第 N 周」窄条，点击展开）。
  bool _weekBarCollapsed = false;

  /// 每分钟自动刷新课程状态（兜底：跨天/数据变化等边界定时器覆盖不到的场景）。
  Timer? _statusTimer;

  /// 精确刷新定时器：对准今天最近的下一次状态跳变时刻（见 [_scheduleStatusRefresh]）。
  Timer? _boundaryTimer;

  /// 已对准的跳变边界（HH:mm，秒归零），避免 build 为同一边界重复创建定时器。
  DateTime? _lastBoundary;

  @override
  void initState() {
    super.initState();
    _rules = WeekRules(
      semesterStart: widget.semester.startDate,
      totalWeeks: widget.semester.totalWeeks,
    );
    _week = _clamp(widget.initialWeek ?? _currentWeek());
    _statusTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _boundaryTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(WeekView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.semester != widget.semester) {
      _rules = WeekRules(
        semesterStart: widget.semester.startDate,
        totalWeeks: widget.semester.totalWeeks,
      );
      _week = _clamp(widget.initialWeek ?? _currentWeek());
    }
  }

  int _currentWeek() => _clamp(_rules.weekOfDate(DateTime.now()));

  int _clamp(int week) => week.clamp(1, widget.semester.totalWeeks);

  static bool _isSameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// 精确对准下一次状态跳变时刻：在 build 中按最新数据计算今天最近的上课/
  /// 下课边界，用一次性 [Timer] 精确触发 setState（±250ms 余量），触发后的
  /// 重建会再次对准下一次。同一边界在多次 build 间只创建一次定时器；
  /// 非当前周或今天已无未来跳变时不调度（由每分钟 [._statusTimer] 兜底）。
  void _scheduleStatusRefresh() {
    final DateTime now = DateTime.now();
    if (_rules.weekOfDate(now) != _week) {
      _lastBoundary = null;
      _boundaryTimer?.cancel();
      _boundaryTimer = null;
      return;
    }
    // 今天必须确实落在本周对应列的日期上（开学前/超范围时 `weekOfDate` 会
    // 把不在本周日期内的今天归到边界周，此时该列并非今天，不调度精确刷新）。
    if (!_isSameDate(_rules.weekDate(now.weekday, _week), now)) {
      _lastBoundary = null;
      _boundaryTimer?.cancel();
      _boundaryTimer = null;
      return;
    }
    final List<Course> courses = ref.read(coursesProvider).value ?? const [];
    final List<Period> periods = ref.read(periodsProvider).value ?? const [];
    final List<Holiday> holidays = ref.read(holidaysProvider).value ?? const [];
    final List<Course> todayCourses = courses
        .where((c) =>
            c.weekday == now.weekday &&
            WeekRules.hasClass(c, _week) &&
            !_rules.isCourseHoliday(c, _week, holidays: holidays))
        .toList();
    final DateTime? boundary = nextStatusChangeBoundary(
        courses: todayCourses, periods: periods, now: now);
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
    // 按最新数据对准下一次状态跳变，保证下课/上课即时变色（不滞后一整分钟）。
    _scheduleStatusRefresh();
    final AsyncValue<List<Course>> coursesAsync = ref.watch(coursesProvider);
    final AsyncValue<List<Period>> periodsAsync = ref.watch(periodsProvider);
    final AsyncValue<List<Holiday>> holidaysAsync =
        ref.watch(holidaysProvider);
    final AsyncValue<TimetableStatusSettings> statusSettingsAsync =
        ref.watch(timetableStatusSettingsProvider);
    return Column(
      children: [
        _buildWeekBar(context),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragEnd: (DragEndDetails details) {
              // 左右滑动切周。
              final double? velocity = details.primaryVelocity;
              if (velocity == null) return;
              if (velocity < -300) {
                _nextWeek();
              } else if (velocity > 300) {
                _prevWeek();
              }
            },
            child: _buildGrid(
                context, coursesAsync, periodsAsync, holidaysAsync,
                statusSettingsAsync),
          ),
        ),
      ],
    );
  }

  void _prevWeek() {
    if (_week > 1) setState(() => _week = _week - 1);
  }

  void _nextWeek() {
    if (_week < widget.semester.totalWeeks) {
      setState(() => _week = _week + 1);
    }
  }

  // ------------------------------------------------------------ 周切换栏

  Widget _buildWeekBar(BuildContext context) {
    final DateTime monday = _rules.weekDate(1, _week);
    final DateTime sunday = _rules.weekDate(7, _week);
    final int current = _currentWeek();
    final ThemeData theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 整条点击收起/展开；子级（标题/箭头/本周）的手势天然优先。
      onTap: () => setState(() => _weekBarCollapsed = !_weekBarCollapsed),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: _weekBarCollapsed
              ? _buildCollapsedWeekBar(theme)
              : _buildExpandedWeekBar(theme, monday, sunday, current),
        ),
      ),
    );
  }

  /// 展开态周条：左箭头 + 标题（点击跳周）+ 日期 + 右箭头 + 本周按钮。
  Widget _buildExpandedWeekBar(
    ThemeData theme,
    DateTime monday,
    DateTime sunday,
    int current,
  ) {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          tooltip: '上一周',
          onPressed: _week > 1 ? _prevWeek : null,
        ),
        Expanded(
          child: Column(
            children: [
              // 跳周触发区：仅包住"第 N 周"数字（四周少量内边距），体感即点击数字。
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _jumpToWeek,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 2,
                  ),
                  child: Text(
                    '第 $_week 周',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              Text(
                '${formatMonthDay(monday)} - ${formatMonthDay(sunday)}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          tooltip: '下一周',
          onPressed: _week < widget.semester.totalWeeks ? _nextWeek : null,
        ),
        TextButton.icon(
          onPressed:
              _week == current ? null : () => setState(() => _week = current),
          icon: const Icon(Icons.my_location, size: 16),
          label: const Text('本周'),
        ),
      ],
    );
  }

  /// 收起态周条：仅居中显示「第 N 周」+ 展开提示图标，点击任意处展开。
  Widget _buildCollapsedWeekBar(ThemeData theme) {
    return SizedBox(
      height: 36,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 左右对称占位，与展开态的箭头区域对齐。
          const SizedBox(width: 48),
          Text(
            '第 $_week 周',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.expand_more, size: 18),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  /// 弹出数字输入框跳转到指定周（校验 1 ~ totalWeeks，非法不跳转）。
  Future<void> _jumpToWeek() async {
    final int? value = await showDialog<int>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _WeekJumpDialog(totalWeeks: widget.semester.totalWeeks),
    );
    if (value == null || !mounted) return;
    setState(() => _week = value);
  }

  // ------------------------------------------------------------ 网格

  Widget _buildGrid(
    BuildContext context,
    AsyncValue<List<Course>> coursesAsync,
    AsyncValue<List<Period>> periodsAsync,
    AsyncValue<List<Holiday>> holidaysAsync,
    AsyncValue<TimetableStatusSettings> statusSettingsAsync,
  ) {
    return coursesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => const Center(child: Text('课程加载失败')),
      data: (courses) => periodsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('节次加载失败')),
        data: (periods) => holidaysAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => const Center(child: Text('停课记录加载失败')),
          data: (holidays) => statusSettingsAsync.when(
            loading: () =>
                const Center(child: CircularProgressIndicator()),
            error: (_, _) => const Center(child: Text('课表设置加载失败')),
            data: (statusSettings) => _buildGridData(
                context, courses, periods, holidays, statusSettings),
          ),
        ),
      ),
    );
  }

  Widget _buildGridData(
    BuildContext context,
    List<Course> courses,
    List<Period> periods,
    List<Holiday> holidays,
    TimetableStatusSettings statusSettings,
  ) {
    if (periods.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '暂无节次配置\n请从右上角菜单进入「节次时间」恢复内置模板或添加节次',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }

    // 本周有课（周次判定）且非停课（停课优先）的课程。
    final List<Course> visible = courses
        .where((c) =>
            WeekRules.hasClass(c, _week) &&
            !_rules.isCourseHoliday(c, _week, holidays: holidays))
        .toList();
    final List<List<Course>> byDay = List.generate(8, (_) => <Course>[]);
    for (final Course c in visible) {
      byDay[c.weekday].add(c);
    }
    final List<List<CourseSlot>> slotsByDay =
        List.generate(8, (d) => computeCourseSlots(byDay[d]));

    final DateTime today = DateTime.now();
    final bool todayInWeek = _rules.weekOfDate(today) == _week;

    final int periodCount = periods.length;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double dayWidth = (constraints.maxWidth - _timeColWidth) / 7;
        return Column(
          children: [
            // 固定表头行：不随内容滚动（sticky）。
            _buildFixedHeaderRow(context, dayWidth, todayInWeek, today),
            Expanded(
              child: SingleChildScrollView(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildTimeColumn(periods),
                    Expanded(
                      child: Row(
                        children: [
                          for (int d = 1; d <= 7; d++)
                            Expanded(
                              child: _buildDayColumn(
                                context,
                                weekday: d,
                                slots: slotsByDay[d],
                                dayWidth: dayWidth,
                                isToday: todayInWeek && _isSameDate(_rules.weekDate(d, _week), today),
                                periodCount: periodCount,
                                periods: periods,
                                today: today,
                                todayInWeek: todayInWeek,
                                statusSettings: statusSettings,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 固定的日期表头行：不透明背景盖住下方滚动内容，滚动时保持不动。
  Widget _buildFixedHeaderRow(
    BuildContext context,
    double dayWidth,
    bool todayInWeek,
    DateTime today,
  ) {
    final ThemeData theme = Theme.of(context);
    return Container(
      height: _headerHeight,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: theme.dividerColor.withValues(alpha: 0.4)),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: _timeColWidth),
          for (int d = 1; d <= 7; d++)
            SizedBox(
              width: dayWidth,
              child: _buildDayHeader(
                theme,
                weekday: d,
                date: _rules.weekDate(d, _week),
                isToday: todayInWeek && _isSameDate(_rules.weekDate(d, _week), today),
              ),
            ),
        ],
      ),
    );
  }

  /// 表头单元格：星期 + 日期（今日主色加粗）。
  Widget _buildDayHeader(
    ThemeData theme, {
    required int weekday,
    required DateTime date,
    required bool isToday,
  }) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(weekdayLabel(weekday), style: theme.textTheme.bodySmall),
        // 长日期（如 12月30日）在窄列宽下会换行溢出，FittedBox 缩放保持单行完整。
        SizedBox(
          width: double.infinity,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              formatMonthDay(date),
              maxLines: 1,
              style: isToday
                  ? theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    )
                  : theme.textTheme.labelSmall,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTimeColumn(List<Period> periods) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      width: _timeColWidth,
      child: Column(
        children: [
          for (final Period p in periods)
            SizedBox(
              height: _rowHeight,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('${p.index}', style: theme.textTheme.bodySmall),
                    Text(
                      p.startTime,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDayColumn(
    BuildContext context, {
    required int weekday,
    required List<CourseSlot> slots,
    required double dayWidth,
    required bool isToday,
    required int periodCount,
    required List<Period> periods,
    required DateTime today,
    required bool todayInWeek,
    required TimetableStatusSettings statusSettings,
  }) {
    final ThemeData theme = Theme.of(context);
    final DateTime date = _rules.weekDate(weekday, _week);
    return GestureDetector(
      onTap: () => _openDayView(date),
      child: SizedBox(
        width: dayWidth,
        height: periodCount * _rowHeight,
        child: Stack(
          children: [
            // 今天高亮背景。
            if (isToday)
              Positioned.fill(
                child: Container(
                  color: theme.colorScheme.primary.withValues(alpha: 0.07),
                ),
              ),
            // 横向分隔线（节次行之间）。
            for (int p = 1; p <= periodCount; p++)
              Positioned(
                top: p * _rowHeight - 0.5,
                left: 0,
                right: 0,
                child: Container(
                  height: 1,
                  color: theme.dividerColor.withValues(alpha: 0.4),
                ),
              ),
            // 课程块（同时间并排）；仅 today 列算状态，其余列为 null。
            for (final CourseSlot slot in slots)
              _buildCourseBlock(
                context,
                slot,
                dayWidth,
                status: isToday
                    ? courseStatusOf(
                        course: slot.course,
                        periods: periods,
                        now: today,
                        isTodayWeek: todayInWeek,
                      )
                    : null,
                statusSettings: statusSettings,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCourseBlock(
    BuildContext context,
    CourseSlot slot,
    double dayWidth, {
    required CourseStatus? status,
    required TimetableStatusSettings statusSettings,
  }) {
    final Course c = slot.course;
    final double left = dayWidth * slot.lane / slot.laneCount;
    final double width = dayWidth / slot.laneCount;
    final double top = (c.startPeriod - 1) * _rowHeight;
    final int span = (c.endPeriod - c.startPeriod + 1) < 1 ? 1 : (c.endPeriod - c.startPeriod + 1);
    final double height = span * _rowHeight;
    final Color? color =
        resolveCourseColor(course: c, status: status, settings: statusSettings);
    final bool isFinished = status == CourseStatus.finished;
    return Positioned(
      left: left + 1,
      top: top + 1,
      width: width - 2,
      height: height - 2,
      child: CourseCard(
        course: c,
        color: color,
        onTap: () => _openCourse(c),
        compact: true,
        // 已结束文字淡化/细化依赖状态色总开关（关闭后一并失效）。
        finishedTextFade: statusSettings.statusColorsEnabled &&
            isFinished &&
            statusSettings.finishedTextFade,
        finishedTextThin: statusSettings.statusColorsEnabled &&
            isFinished &&
            statusSettings.finishedTextThin,
      ),
    );
  }

  // ------------------------------------------------------------ 导航

  Future<void> _openCourse(Course course) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CourseFormPage(semester: widget.semester, course: course),
      ),
    );
  }

  Future<void> _openDayView(DateTime date) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DayViewPage(semester: widget.semester, date: date),
      ),
    );
  }
}

/// 跳周数字输入对话框：自管 [TextEditingController] 生命周期（随对话框路由完整退出后
/// 才 dispose，避免在退出动画期间访问已销毁的 controller 导致崩溃）。
/// 校验 1 ~ totalWeeks，非法输入就地提示且不关闭，取消返回 null。
class _WeekJumpDialog extends StatefulWidget {
  const _WeekJumpDialog({required this.totalWeeks});

  final int totalWeeks;

  @override
  State<_WeekJumpDialog> createState() => _WeekJumpDialogState();
}

class _WeekJumpDialogState extends State<_WeekJumpDialog> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _focusTimer;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 等对话框淡入动画（约 150ms）播完再弹出键盘，避免键盘上升与对话框入场
    // 动画叠加，造成对话框被键盘推着上下移动时发卡。200ms 后再聚焦。
    _focusTimer = Timer(const Duration(milliseconds: 200), () {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusTimer?.cancel();
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final int? v = int.tryParse(_controller.text.trim());
    if (v == null || v < 1 || v > widget.totalWeeks) {
      setState(() => _error = '请输入 1~${widget.totalWeeks} 之间的整数');
      return;
    }
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    // 移除键盘 inset 并固定在屏幕上部：键盘弹出时弹窗纹丝不动、也不会被键盘
    // 遮挡。若不移除，Dialog 会把键盘高度加进内边距逐帧重新瞄准地把弹窗往上推
    // （AnimatedPadding 100ms），造成橡皮筋式发卡。
    return MediaQuery.removeViewInsets(
      removeBottom: true,
      context: context,
      child: AlertDialog(
        alignment: Alignment.topCenter,
        insetPadding: const EdgeInsets.fromLTRB(40, 100, 40, 40),
        title: const Text('跳转到第几周'),
        content: TextField(
          controller: _controller,
          focusNode: _focusNode,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: '1 ~ ${widget.totalWeeks}',
            errorText: _error,
          ),
          onSubmitted: (_) => _submit(),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: _submit,
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}
