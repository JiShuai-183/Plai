import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/course.dart';
import '../../data/models/holiday.dart';
import '../../data/models/period.dart';
import '../../data/models/semester.dart';
import '../../shared/layout_breakpoints.dart';
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
  static const double _timeColWidth = 48;
  static const double _headerHeight = 46;

  /// 桌面空间充足时的标准节次高度；窄屏/低分辨率桌面会等比压缩到恰好显示
  /// 12 节，避免启动后还要滚动才能看到晚间课程。
  static const double _preferredRowHeight = 64;

  /// 空天列压缩后的列宽（本周该天没有任何课程；竖排周几刚好放下，省出的
  /// 宽度均分给有课天）。
  static const double _emptyColWidth = 20;

  late WeekRules _rules;
  late int _week;

  /// 横向分页控制器：一页 = 一个学期周次（页 index = 周次 - 1）。
  /// 连续滑动每次都走真实分页动画，无需回中。
  late final PageController _pageController;

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
    _pageController = PageController(initialPage: _week - 1);
    _statusTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      // 不在当前周页：无实时状态/今日高亮变化 → 跳过整页 setState（性能）。
      if (_rules.weekOfDate(DateTime.now()) != _week) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _boundaryTimer?.cancel();
    _pageController.dispose();
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pageController.jumpToPage(_week - 1);
      });
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
        .where(
          (c) =>
              c.weekday == now.weekday &&
              WeekRules.hasClass(c, _week) &&
              !_rules.isCourseHoliday(c, _week, holidays: holidays),
        )
        .toList();
    final DateTime? boundary = nextStatusChangeBoundary(
      courses: todayCourses,
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
    // 按最新数据对准下一次状态跳变，保证下课/上课即时变色（不滞后一整分钟）。
    _scheduleStatusRefresh();
    final AsyncValue<List<Course>> coursesAsync = ref.watch(coursesProvider);
    final AsyncValue<List<Period>> periodsAsync = ref.watch(periodsProvider);
    final AsyncValue<List<Holiday>> holidaysAsync = ref.watch(holidaysProvider);
    final AsyncValue<TimetableStatusSettings> statusSettingsAsync = ref.watch(
      timetableStatusSettingsProvider,
    );
    // 一页=一学期周次（页 index = 周次-1）的横向翻页，水平拖拽完全跟手；
    // **松手时**按位移/速度判定切周（有速度或已过约 1/3 就切，避免“滑了却
    // 没到下一周”）。不显示学期名/周条，仅课表本身。
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _onPageDragUpdate,
      onHorizontalDragEnd: _onPageDragEnd,
      onHorizontalDragCancel: _onPageDragCancel,
      child: PageView.builder(
        controller: _pageController,
        // 用手写拖拽跟手 + 自定义落点判定，避免系统分页“差一点回弹”。
        physics: const NeverScrollableScrollPhysics(),
        itemCount: widget.semester.totalWeeks,
        itemBuilder: (BuildContext context, int index) {
          final int week = index + 1;
          return _buildWeekPage(
            context,
            week,
            coursesAsync,
            periodsAsync,
            holidaysAsync,
            statusSettingsAsync,
          );
        },
      ),
    );
  }

  /// 水平拖拽中：让页面像素严格跟随手指位移（不自动定格/回弹）。
  void _onPageDragUpdate(DragUpdateDetails details) {
    final ScrollPosition pos = _pageController.position;
    if (!pos.hasContentDimensions) return;
    final double? delta = details.primaryDelta;
    if (delta == null) return;
    pos.jumpTo((pos.pixels - delta).clamp(0.0, pos.maxScrollExtent));
  }

  void _onPageDragEnd(DragEndDetails details) =>
      _settlePageDrag(details.primaryVelocity ?? 0);

  void _onPageDragCancel() => _settlePageDrag(0);

  /// 松手判定：以「当前周」为基准，按拖拽方向判定——
  /// - 有足够速度：往左拖（velocity<0）→ 下一周；往右拖 → 上一周；
  /// - 否则：相对当前页位移超过 20% 就切向对应方向，不足则回原位。
  void _settlePageDrag(double velocity) {
    final ScrollPosition pos = _pageController.position;
    if (!pos.hasContentDimensions) return;
    final int maxPage = widget.semester.totalWeeks - 1;
    final double pageFloat = pos.pixels / pos.viewportDimension;
    final double current = (_week - 1).toDouble();

    int target;
    if (velocity.abs() > 90) {
      target = (velocity < 0 ? current + 1 : current - 1).round();
    } else if (pageFloat > current + 0.2) {
      target = current.round() + 1; // 左拖未甩 → 下一周
    } else if (pageFloat < current - 0.2) {
      target = current.round() - 1; // 右拖未甩 → 上一周
    } else {
      target = current.round(); // 回原位
    }
    target = target.clamp(0, maxPage);
    _pageController.animateToPage(
      target,
      // 切周后的滑动动画时长（更慢更顺滑）。
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
    );
    final int week = target + 1;
    if (week != _week) setState(() => _week = week);
  }

  /// 单页内容 = 该周的「周条 + 网格」（整页随 PageView 跟手滑动）。
  Widget _buildWeekPage(
    BuildContext context,
    int week,
    AsyncValue<List<Course>> coursesAsync,
    AsyncValue<List<Period>> periodsAsync,
    AsyncValue<List<Holiday>> holidaysAsync,
    AsyncValue<TimetableStatusSettings> statusSettingsAsync,
  ) {
    // 每页只渲染课表；「第 N 周」已嵌在表头左上角（可点输入跳周）。
    return _buildGrid(
      context,
      week,
      coursesAsync,
      periodsAsync,
      holidaysAsync,
      statusSettingsAsync,
    );
  }

  /// 直接跳到 [week]（页 index = week-1；点「第 N 周」输入跳周用）。
  void _goToWeek(int week) {
    final int target = _clamp(week);
    if (target == _week) return;
    setState(() => _week = target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pageController.jumpToPage(target - 1);
    });
  }

  /// 弹出数字输入框跳转到指定周（校验 1 ~ totalWeeks，非法不跳转）。
  Future<void> _jumpToWeekDialog() async {
    final int? value = await showDialog<int>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _WeekJumpDialog(totalWeeks: widget.semester.totalWeeks),
    );
    if (value == null || !mounted) return;
    _goToWeek(value);
  }

  // ------------------------------------------------------------ 网格

  Widget _buildGrid(
    BuildContext context,
    int week,
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
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const Center(child: Text('课表设置加载失败')),
            data: (statusSettings) => _buildGridData(
              context,
              week,
              courses,
              periods,
              holidays,
              statusSettings,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGridData(
    BuildContext context,
    int week,
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
        .where(
          (c) =>
              WeekRules.hasClass(c, week) &&
              !_rules.isCourseHoliday(c, week, holidays: holidays),
        )
        .toList();
    final List<List<Course>> byDay = List.generate(8, (_) => <Course>[]);
    for (final Course c in visible) {
      byDay[c.weekday].add(c);
    }
    final List<List<CourseSlot>> slotsByDay = List.generate(
      8,
      (d) => computeCourseSlots(byDay[d]),
    );

    final DateTime today = DateTime.now();
    final bool todayInWeek = _rules.weekOfDate(today) == week;

    final int periodCount = periods.length;
    final bool isWide = WideLayoutScope.isWideOf(context);
    const double scale = 1.0;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 每个节次使用一致行高。不能因某一周该节次暂无课而压缩，否则第 9–12
        // 节会变成几像素高、无法添加或查看晚间课程。
        final List<double> rowHeights = _computeRowHeights(
          periodCount,
          availableHeight: constraints.maxHeight,
          isWide: isWide,
          scale: scale,
        );
        final double timeColumnWidth = _timeColWidth * scale;
        // 本周天列宽：空天压缩，省下的空间平均分给非空天（总宽不变）。
        final List<double> colWidths = _computeColWidths(
          visible,
          constraints.maxWidth - timeColumnWidth,
        );
        // 各天是否有课：空天表头只显示竖排周几、不显示日期。
        final List<bool> dayHasCourse = List<bool>.filled(8, false);
        for (final Course c in visible) {
          dayHasCourse[c.weekday] = true;
        }
        final double totalHeight = rowHeights.fold(
          0.0,
          (double acc, double h) => acc + h,
        );
        return Column(
          children: [
            // 固定表头行：不随内容滚动（sticky）。
            _buildFixedHeaderRow(
              context,
              colWidths,
              dayHasCourse,
              todayInWeek,
              today,
              week,
              scale: scale,
              timeColumnWidth: timeColumnWidth,
            ),
            Expanded(
              child: SingleChildScrollView(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    RepaintBoundary(
                      child: _buildTimeColumn(
                        periods,
                        rowHeights: rowHeights,
                        scale: scale,
                        timeColumnWidth: timeColumnWidth,
                      ),
                    ),
                    Expanded(
                      child: Row(
                        children: [
                          // 每列一个 RepaintBoundary：分钟级状态刷新时只重绘
                          // 状态变化的列，不整片重绘（性能）。
                          for (int d = 1; d <= 7; d++)
                            RepaintBoundary(
                              child: _buildDayColumn(
                                context,
                                weekday: d,
                                week: week,
                                slots: slotsByDay[d],
                                colWidth: colWidths[d],
                                totalHeight: totalHeight,
                                rowHeights: rowHeights,
                                isToday:
                                    todayInWeek &&
                                    _isSameDate(
                                      _rules.weekDate(d, week),
                                      today,
                                    ),
                                periodCount: periodCount,
                                periods: periods,
                                today: today,
                                todayInWeek: todayInWeek,
                                statusSettings: statusSettings,
                                scale: scale,
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
    List<double> colWidths,
    List<bool> dayHasCourse,
    bool todayInWeek,
    DateTime today,
    int week, {
    required double scale,
    required double timeColumnWidth,
  }) {
    final ThemeData theme = Theme.of(context);
    return Container(
      height: _headerHeight * scale,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: theme.dividerColor.withValues(alpha: 0.4)),
        ),
      ),
      child: Row(
        children: [
          // 表头左上角：节次列上方显示「第 N 周」（点击输入数字跳周）。
          InkWell(
            onTap: _jumpToWeekDialog,
            borderRadius: BorderRadius.circular(6 * scale),
            child: SizedBox(
              width: timeColumnWidth,
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 2 * scale),
                    child: Text(
                      '第 $week 周',
                      maxLines: 1,
                      style: _scaledTextStyle(
                        theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        scale,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          for (int d = 1; d <= 7; d++)
            SizedBox(
              width: colWidths[d],
              child: _buildDayHeader(
                theme,
                weekday: d,
                date: _rules.weekDate(d, week),
                isToday:
                    todayInWeek && _isSameDate(_rules.weekDate(d, week), today),
                isEmpty: !dayHasCourse[d],
                scale: scale,
              ),
            ),
        ],
      ),
    );
  }

  /// 表头单元格：有课天显示「周几 + 日期」（今日主色加粗）；空天只显示
  /// 竖排的周几（不显示日期，省出窄列给有课天让位）。
  Widget _buildDayHeader(
    ThemeData theme, {
    required int weekday,
    required DateTime date,
    required bool isToday,
    required bool isEmpty,
    required double scale,
  }) {
    if (isEmpty) {
      // 竖排周几：'周一' → '周' / '一' 逐字一行，垂直居中。
      final TextStyle? style =
          _scaledTextStyle(theme.textTheme.bodySmall, scale)?.copyWith(
            height: 1.15,
            color: isToday ? theme.colorScheme.primary : null,
            fontWeight: isToday ? FontWeight.w700 : null,
          );
      return Center(
        child: Text(
          weekdayLabel(weekday).split('').join('\n'),
          textAlign: TextAlign.center,
          style: style,
        ),
      );
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          weekdayLabel(weekday),
          style: _scaledTextStyle(theme.textTheme.bodySmall, scale),
        ),
        // 长日期（如 12月30日）在窄列宽下会换行溢出，FittedBox 缩放保持单行完整。
        SizedBox(
          width: double.infinity,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              formatMonthDay(date),
              maxLines: 1,
              style: isToday
                  ? _scaledTextStyle(
                      theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                      scale,
                    )
                  : _scaledTextStyle(theme.textTheme.labelSmall, scale),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTimeColumn(
    List<Period> periods, {
    required List<double> rowHeights,
    required double scale,
    required double timeColumnWidth,
  }) {
    final ThemeData theme = Theme.of(context);
    // 每行底边横线（与课程区节次分隔线对齐）；时间列与课程区之间不再画右侧分界线。
    final Color line = theme.dividerColor.withValues(alpha: 0.4);
    return SizedBox(
      width: timeColumnWidth,
      child: Column(
        children: [
          for (int i = 0; i < periods.length; i++)
            Container(
              height: i < rowHeights.length
                  ? rowHeights[i]
                  : _preferredRowHeight,
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: line)),
              ),
              // 各高校的作息时间不同，课表网格仅标示节次；具体起止时间仍可
              // 在节次设置中维护，供今日课程和提醒等需要时间的功能使用。
              child: Center(
                child: Text(
                  '第${periods[i].index}节',
                  style: _scaledTextStyle(theme.textTheme.bodySmall, scale),
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
    required int week,
    required List<CourseSlot> slots,
    required double colWidth,
    required double totalHeight,
    required List<double> rowHeights,
    required bool isToday,
    required int periodCount,
    required List<Period> periods,
    required DateTime today,
    required bool todayInWeek,
    required TimetableStatusSettings statusSettings,
    required double scale,
  }) {
    final ThemeData theme = Theme.of(context);
    final DateTime date = _rules.weekDate(weekday, week);
    // 相邻同课（name+teacher+location 全同）且全程未并排（laneCount==1）的
    // slot 合并成组，渲染同一个色块；其余 slot 各自成组渲染。
    final List<_MergedGroup> groups = _groupSlots(slots);
    // 连排课块 / 合并组内部的节次边界（课程覆盖区间内）不画横线，视觉连成一片。
    final Set<int> coveredBorders = <int>{};
    for (final CourseSlot s in slots) {
      for (int p = s.course.startPeriod; p < s.course.endPeriod; p++) {
        coveredBorders.add(p);
      }
    }
    for (final _MergedGroup g in groups) {
      if (!g.merged) continue;
      for (int p = g.startPeriod; p < g.endPeriod; p++) {
        coveredBorders.add(p);
      }
    }
    return GestureDetector(
      onTap: () => _openDayView(date),
      child: SizedBox(
        width: colWidth,
        height: totalHeight,
        child: Stack(
          children: [
            // 今天高亮背景。
            if (isToday)
              Positioned.fill(
                child: Container(
                  color: theme.colorScheme.primary.withValues(alpha: 0.07),
                ),
              ),
            // 横向分隔线（节次行之间，位置随动态行高累积）；连排课/合并组内部
            // 边界跳过（块内无线）。
            for (int p = 1; p <= periodCount; p++)
              if (!coveredBorders.contains(p))
                Positioned(
                  top: _rowTop(rowHeights, p + 1) - 0.5,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 1,
                    color: theme.dividerColor.withValues(alpha: 0.4),
                  ),
                ),
            // 课程块：合并组渲染单个色块，单课按现有逻辑；仅 today 列逐节算
            // 状态，其余列全部 null。
            for (final _MergedGroup g in groups)
              if (g.merged)
                _buildMergedBlock(
                  context,
                  g,
                  colWidth,
                  rowHeights,
                  periods: periods,
                  isToday: isToday,
                  today: today,
                  todayInWeek: todayInWeek,
                  statusSettings: statusSettings,
                  scale: scale,
                )
              else
                _buildCourseBlock(
                  context,
                  g.slots.first,
                  colWidth,
                  rowHeights,
                  periods: periods,
                  isToday: isToday,
                  today: today,
                  todayInWeek: todayInWeek,
                  statusSettings: statusSettings,
                  scale: scale,
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildCourseBlock(
    BuildContext context,
    CourseSlot slot,
    double dayWidth,
    List<double> rowHeights, {
    required List<Period> periods,
    required bool isToday,
    required DateTime today,
    required bool todayInWeek,
    required TimetableStatusSettings statusSettings,
    required double scale,
  }) {
    final Course c = slot.course;
    final double left = dayWidth * slot.lane / slot.laneCount;
    final double width = dayWidth / slot.laneCount;
    final (double top, double height) = _rowOffset(
      rowHeights,
      c.startPeriod,
      c.endPeriod,
    );
    final int span = (c.endPeriod - c.startPeriod + 1) < 1
        ? 1
        : (c.endPeriod - c.startPeriod + 1);

    // 逐节独立状态与颜色：仅 today 列（isToday && todayInWeek）逐节判定，
    // 其余列全部 null → 课程自选色（无色 → 中性）。
    final List<Color?> perPeriodColors = <Color?>[];
    for (int i = 0; i < span; i++) {
      final Period? period = _periodByIndex(periods, c.startPeriod + i);
      final CourseStatus? s = (isToday && todayInWeek && period != null)
          ? courseStatusOfPeriod(period: period, now: today)
          : null;
      perPeriodColors.add(
        resolveCourseColor(course: c, status: s, settings: statusSettings),
      );
    }

    // 已结束淡化/细化按「整门课」判定，沿用现有 courseStatusOf 逻辑。
    final bool isFinished =
        isToday &&
        courseStatusOf(
              course: c,
              periods: periods,
              now: today,
              isTodayWeek: todayInWeek,
            ) ==
            CourseStatus.finished;
    return Positioned(
      left: left + 1,
      top: top + 1,
      width: width - 2,
      height: height - 2,
      child: SegmentedCourseBlock(
        course: c,
        perPeriodColors: perPeriodColors,
        onTap: () => _openCourse(c),
        compact: true,
        // 连排课（跨 ≥2 节）信息展开显示。
        expanded: span >= 2,
        // 已结束文字淡化/细化依赖状态色总开关（关闭后一并失效）。
        finishedTextFade:
            statusSettings.statusColorsEnabled &&
            isFinished &&
            statusSettings.finishedTextFade,
        finishedTextThin:
            statusSettings.statusColorsEnabled &&
            isFinished &&
            statusSettings.finishedTextThin,
        scale: scale,
      ),
    );
  }

  /// 第 [periodIndex1based]（1 起）节次行顶边的累积偏移（前序各行高之和）。
  double _rowTop(List<double> rowHeights, int periodIndex1based) {
    double top = 0;
    for (int i = 0; i < periodIndex1based - 1 && i < rowHeights.length; i++) {
      top += rowHeights[i];
    }
    return top;
  }

  /// 从 [startPeriod1based] 到 [endPeriod1based]（均 1 起、含）的行区间
  /// (top, height)，供课程块 / 合并组定位。
  (double, double) _rowOffset(
    List<double> rowHeights,
    int startPeriod1based,
    int endPeriod1based,
  ) {
    final double top = _rowTop(rowHeights, startPeriod1based);
    double height = 0;
    for (
      int i = startPeriod1based - 1;
      i < endPeriod1based && i < rowHeights.length;
      i++
    ) {
      height += rowHeights[i];
    }
    return (top, height);
  }

  /// 每个节次始终占用相同行高。空行也必须可见、可点击，尤其是晚间的第 9–12
  /// 节，不能因为当前周暂无课而被压缩。
  List<double> _computeRowHeights(
    int periodCount, {
    required double availableHeight,
    required bool isWide,
    required double scale,
  }) {
    if (periodCount == 0) return const <double>[];

    double baseRowHeight = _preferredRowHeight;
    if (isWide && availableHeight.isFinite) {
      final double fittedHeight =
          (availableHeight - _headerHeight) / periodCount;
      if (fittedHeight > 0 && fittedHeight < baseRowHeight) {
        baseRowHeight = fittedHeight;
      }
    }
    return List<double>.filled(periodCount, baseRowHeight * scale);
  }

  /// 本周每列宽：无课的空天压缩为 [_emptyColWidth]，省下的空间平均分给非空天
  /// （总宽保持 [totalWidth]）；全部为空时均分 totalWidth/7。
  List<double> _computeColWidths(List<Course> visible, double totalWidth) {
    final List<int> perDayCourseCount = List<int>.filled(8, 0);
    for (final Course c in visible) {
      perDayCourseCount[c.weekday]++;
    }
    final List<double> widths = List<double>.filled(8, 0);
    int emptyDays = 0;
    for (int d = 1; d <= 7; d++) {
      if (perDayCourseCount[d] == 0) emptyDays++;
    }
    final int nonEmptyDays = 7 - emptyDays;
    if (nonEmptyDays == 0) {
      final double w = totalWidth / 7;
      for (int d = 1; d <= 7; d++) {
        widths[d] = w;
      }
      return widths;
    }
    final double share = totalWidth - emptyDays * _emptyColWidth;
    final double nonEmptyWidth = share > 0 ? share / nonEmptyDays : 0.0;
    for (int d = 1; d <= 7; d++) {
      widths[d] = perDayCourseCount[d] == 0 ? _emptyColWidth : nonEmptyWidth;
    }
    return widths;
  }

  /// 合并组色块：覆盖 [组内第一门 startPeriod, 组内最后一门 endPeriod]，逐节
  /// 独立状态与颜色（owner course 为该节所属课程，找不到用组内第一门课），
  /// 课程信息 / 点击编辑 / finished 判定均用组内第一门课。
  Widget _buildMergedBlock(
    BuildContext context,
    _MergedGroup group,
    double dayWidth,
    List<double> rowHeights, {
    required List<Period> periods,
    required bool isToday,
    required DateTime today,
    required bool todayInWeek,
    required TimetableStatusSettings statusSettings,
    required double scale,
  }) {
    final Course c = group.first;
    final (double top, double height) = _rowOffset(
      rowHeights,
      group.startPeriod,
      group.endPeriod,
    );
    final int span = group.endPeriod - group.startPeriod + 1;
    final List<Course> groupCourses = group.courses;

    // 逐节独立状态与颜色：仅 today 列（isToday && todayInWeek）逐节判定，
    // 其余列全部 null → 课程自选色（无色 → 中性）。
    final List<Color?> perPeriodColors = <Color?>[];
    for (int i = 0; i < span; i++) {
      final int absPeriod = group.startPeriod + i;
      Course owner = c;
      for (final Course gc in groupCourses) {
        if (gc.startPeriod <= absPeriod && absPeriod <= gc.endPeriod) {
          owner = gc;
          break;
        }
      }
      final Period? period = _periodByIndex(periods, absPeriod);
      final CourseStatus? s = (isToday && todayInWeek && period != null)
          ? courseStatusOfPeriod(period: period, now: today)
          : null;
      perPeriodColors.add(
        resolveCourseColor(course: owner, status: s, settings: statusSettings),
      );
    }

    // 已结束淡化/细化按「组内第一门课」整门判定，沿用现有 courseStatusOf 逻辑。
    final bool isFinished =
        isToday &&
        courseStatusOf(
              course: c,
              periods: periods,
              now: today,
              isTodayWeek: todayInWeek,
            ) ==
            CourseStatus.finished;
    return Positioned(
      left: 1,
      top: top + 1,
      width: dayWidth - 2,
      height: height - 2,
      child: SegmentedCourseBlock(
        course: c,
        perPeriodColors: perPeriodColors,
        onTap: () => _openCourse(c),
        compact: true,
        // 合并组跨 ≥2 节，信息展开显示。
        expanded: span >= 2,
        // 已结束文字淡化/细化依赖状态色总开关（关闭后一并失效）。
        finishedTextFade:
            statusSettings.statusColorsEnabled &&
            isFinished &&
            statusSettings.finishedTextFade,
        finishedTextThin:
            statusSettings.statusColorsEnabled &&
            isFinished &&
            statusSettings.finishedTextThin,
        scale: scale,
      ),
    );
  }

  TextStyle? _scaledTextStyle(TextStyle? style, double scale) {
    if (style == null) return null;
    return style.copyWith(fontSize: (style.fontSize ?? 14) * scale);
  }

  /// 按节次序号查找节次，找不到返回 null。
  Period? _periodByIndex(List<Period> periods, int index) {
    for (final Period p in periods) {
      if (p.index == index) return p;
    }
    return null;
  }

  // ------------------------------------------------------------ 导航

  Future<void> _openCourse(Course course) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            CourseFormPage(semester: widget.semester, course: course),
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

/// 相邻同课合并组：同一天相邻节次（前门 endPeriod+1 == 后门 startPeriod）且
/// name+teacher+location 全同、全程未并排（laneCount==1）的课程渲染成同一个
/// 色块（视觉像同一堂课，中间无间隔）。组内课程按 startPeriod 升序。
class _MergedGroup {
  _MergedGroup(CourseSlot slot) : slots = <CourseSlot>[slot];

  /// 组内全部 slot（按 startPeriod 升序）。
  final List<CourseSlot> slots;

  void add(CourseSlot slot) => slots.add(slot);

  /// 组内第一门课（合并组起点课程；课程信息 / 点击编辑 / finished 判定用它）。
  Course get first => slots.first.course;

  /// 组内全部课程（按 startPeriod 升序）。
  List<Course> get courses => [for (final CourseSlot s in slots) s.course];

  /// 合并组整体覆盖的起始节次。
  int get startPeriod => slots.first.course.startPeriod;

  /// 合并组整体覆盖的结束节次。
  int get endPeriod => slots.last.course.endPeriod;

  /// 是否为合并组（≥2 门课），否则是单课。
  bool get merged => slots.length > 1;

  /// 组内所有 slot 均为未并排（laneCount==1）。
  bool get laneCountOne {
    for (final CourseSlot s in slots) {
      if (s.laneCount != 1) return false;
    }
    return true;
  }
}

/// 将当天已按 startPeriod 排序的 slots 聚合：相邻同课（前门 endPeriod+1 ==
/// 后门 startPeriod 且 name+teacher+location 全同）且全程未并排（laneCount==1）
/// 的 slot 合并成组；其余各自成组。
List<_MergedGroup> _groupSlots(List<CourseSlot> slots) {
  final List<_MergedGroup> groups = <_MergedGroup>[];
  for (final CourseSlot slot in slots) {
    final _MergedGroup? last = groups.isEmpty ? null : groups.last;
    final bool mergeable =
        last != null &&
        last.laneCountOne &&
        slot.laneCount == 1 &&
        last.endPeriod + 1 == slot.course.startPeriod &&
        _sameCourseIdentity(last.first, slot.course);
    if (mergeable) {
      last.add(slot);
    } else {
      groups.add(_MergedGroup(slot));
    }
  }
  return groups;
}

/// 课程「身份」是否相同：name + teacher + location 全同（不含 color/weekType 等）。
bool _sameCourseIdentity(Course a, Course b) =>
    a.name == b.name && a.teacher == b.teacher && a.location == b.location;

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
          TextButton(onPressed: _submit, child: const Text('确定')),
        ],
      ),
    );
  }
}
