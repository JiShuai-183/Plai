import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/course.dart';
import '../../data/models/holiday.dart';
import '../../data/models/period.dart';
import '../../data/models/semester.dart';
import 'class_lanes.dart';
import 'color_utils.dart';
import 'course_form_page.dart';
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

  @override
  void initState() {
    super.initState();
    _rules = WeekRules(
      semesterStart: widget.semester.startDate,
      totalWeeks: widget.semester.totalWeeks,
    );
    _week = _clamp(widget.initialWeek ?? _currentWeek());
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

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Course>> coursesAsync = ref.watch(coursesProvider);
    final AsyncValue<List<Period>> periodsAsync = ref.watch(periodsProvider);
    final AsyncValue<List<Holiday>> holidaysAsync =
        ref.watch(holidaysProvider);
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
            child:
                _buildGrid(context, coursesAsync, periodsAsync, holidaysAsync),
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
          data: (holidays) => _buildGridData(context, courses, periods, holidays),
        ),
      ),
    );
  }

  Widget _buildGridData(
    BuildContext context,
    List<Course> courses,
    List<Period> periods,
    List<Holiday> holidays,
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
        return SingleChildScrollView(
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
                          periods: periods,
                          dayWidth: dayWidth,
                          isToday: todayInWeek && today.weekday == d,
                          periodCount: periodCount,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTimeColumn(List<Period> periods) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      width: _timeColWidth,
      child: Column(
        children: [
          const SizedBox(height: _headerHeight),
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
    required List<Period> periods,
    required double dayWidth,
    required bool isToday,
    required int periodCount,
  }) {
    final ThemeData theme = Theme.of(context);
    final DateTime date = _rules.weekDate(weekday, _week);
    return GestureDetector(
      onTap: () => _openDayView(date),
      child: SizedBox(
        width: dayWidth,
        height: _headerHeight + periodCount * _rowHeight,
        child: Stack(
          children: [
            // 今天高亮背景。
            if (isToday)
              Positioned.fill(
                child: Container(
                  color: theme.colorScheme.primary.withValues(alpha: 0.07),
                ),
              ),
            // 横向分隔线（表头下方 + 节次行之间）。
            for (int p = 0; p <= periodCount; p++)
              Positioned(
                top: _headerHeight + p * _rowHeight - 0.5,
                left: 0,
                right: 0,
                child: Container(
                  height: 1,
                  color: theme.dividerColor.withValues(alpha: 0.4),
                ),
              ),
            // 表头：星期 + 日期。
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: _headerHeight,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(weekdayLabel(weekday), style: theme.textTheme.bodySmall),
                  Text(
                    formatMonthDay(date),
                    style: isToday
                        ? theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w700,
                          )
                        : theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
            // 课程块（同时间并排）。
            for (final CourseSlot slot in slots)
              _buildCourseBlock(context, slot, dayWidth),
          ],
        ),
      ),
    );
  }

  Widget _buildCourseBlock(
    BuildContext context,
    CourseSlot slot,
    double dayWidth,
  ) {
    final Course c = slot.course;
    final double left = dayWidth * slot.lane / slot.laneCount;
    final double width = dayWidth / slot.laneCount;
    final double top = _headerHeight + (c.startPeriod - 1) * _rowHeight;
    final int span = (c.endPeriod - c.startPeriod + 1) < 1 ? 1 : (c.endPeriod - c.startPeriod + 1);
    final double height = span * _rowHeight;
    final Color color = colorFromHex(c.color);
    return Positioned(
      left: left + 1,
      top: top + 1,
      width: width - 2,
      height: height - 2,
      child: Material(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _openCourse(c),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            decoration: BoxDecoration(
              border: Border.all(color: color.withValues(alpha: 0.6)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
                if (c.location.isNotEmpty)
                  Text(
                    c.location,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9,
                      color: color.withValues(alpha: 0.8),
                    ),
                  ),
              ],
            ),
          ),
        ),
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
