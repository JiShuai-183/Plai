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
import 'format.dart';
import 'timetable_providers.dart';
import 'week_rules.dart';

/// 日视图：单日节次时间线。
///
/// 展示 [date] 当天有课（周次判定）且非停课的课程，按节次纵向排布，
/// 同时间课程并排。全局停课当天顶部提示原因。
class DayViewPage extends ConsumerStatefulWidget {
  const DayViewPage({super.key, required this.semester, required this.date});

  /// 所属学期。
  final Semester semester;

  /// 要展示的日期（仅年月日参与判定）。
  final DateTime date;

  @override
  ConsumerState<DayViewPage> createState() => _DayViewPageState();
}

class _DayViewPageState extends ConsumerState<DayViewPage> {
  /// 每分钟自动刷新课程状态（跨节次/上完时颜色与文字即时变化）。
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _statusTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  /// 两个日期是否为同一天（仅年月日参与）。
  static bool _isSameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Course>> coursesAsync = ref.watch(coursesProvider);
    final AsyncValue<List<Period>> periodsAsync = ref.watch(periodsProvider);
    final AsyncValue<List<Holiday>> holidaysAsync =
        ref.watch(holidaysProvider);
    final AsyncValue<TimetableStatusSettings> statusSettingsAsync =
        ref.watch(timetableStatusSettingsProvider);
    final WeekRules rules = WeekRules(
      semesterStart: widget.semester.startDate,
      totalWeeks: widget.semester.totalWeeks,
    );
    final int week = rules.clampWeek(rules.weekOfDate(widget.date));

    return Scaffold(
      appBar: AppBar(title: Text(formatDateWeekday(widget.date))),
      body: coursesAsync.when(
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
              data: (statusSettings) => _buildBody(context, courses, periods,
                  holidays, rules, week, statusSettings),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    List<Course> courses,
    List<Period> periods,
    List<Holiday> holidays,
    WeekRules rules,
    int week,
    TimetableStatusSettings statusSettings,
  ) {
    final DateTime now = DateTime.now();
    final bool isToday = _isSameDate(widget.date, now);
    final List<Holiday> globalHolidays = holidays
        .where((h) => h.courseId == null && h.date == widget.date)
        .toList();
    final String holidayReasons =
        globalHolidays.map((h) => h.reason).where((r) => r.isNotEmpty).join('、');

    if (periods.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '暂无节次配置',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }

    // 当天有课（周次判定）且非停课（停课优先）的课程。
    final List<Course> dayCourses = courses
        .where((c) =>
            c.weekday == widget.date.weekday &&
            WeekRules.hasClass(c, week) &&
            !rules.isCourseHoliday(c, week, holidays: holidays))
        .toList();
    final List<CourseSlot> slots = computeCourseSlots(dayCourses);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (globalHolidays.isNotEmpty)
          MaterialBanner(
            leading: const Icon(Icons.event_busy_outlined),
            content: Text(
              holidayReasons.isEmpty ? '停课：放假' : '停课：$holidayReasons',
            ),
            actions: const [SizedBox.shrink()],
          ),
        Expanded(
          child: _buildTimeline(
            context,
            periods,
            slots,
            statusSettings: statusSettings,
            isToday: isToday,
            now: now,
          ),
        ),
      ],
    );
  }

  Widget _buildTimeline(
    BuildContext context,
    List<Period> periods,
    List<CourseSlot> slots, {
    required TimetableStatusSettings statusSettings,
    required bool isToday,
    required DateTime now,
  }) {
    final ThemeData theme = Theme.of(context);
    const double timeColWidth = 64;
    const double rowHeight = 56;
    final int periodCount = periods.length;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double dayWidth = constraints.maxWidth - timeColWidth;
        return SingleChildScrollView(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: timeColWidth,
                child: Column(
                  children: [
                    for (final Period p in periods)
                      SizedBox(
                        height: rowHeight,
                        child: Center(
                          child: Text(
                            '${p.index} 节\n${p.startTime}',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(
                width: dayWidth,
                height: periodCount * rowHeight,
                child: Stack(
                  children: [
                    for (int p = 0; p <= periodCount; p++)
                      Positioned(
                        top: p * rowHeight - 0.5,
                        left: 0,
                        right: 0,
                        child: Container(
                          height: 1,
                          color: theme.dividerColor.withValues(alpha: 0.4),
                        ),
                      ),
                    // 课程块；仅今天算状态，其余日期一律 null。
                    for (final CourseSlot slot in slots)
                      _buildCourseBlock(
                        context,
                        slot,
                        dayWidth,
                        rowHeight,
                        status: isToday
                            ? courseStatusOf(
                                course: slot.course,
                                periods: periods,
                                now: now,
                                isTodayWeek: true,
                              )
                            : null,
                        statusSettings: statusSettings,
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

  Widget _buildCourseBlock(
    BuildContext context,
    CourseSlot slot,
    double dayWidth,
    double rowHeight, {
    required CourseStatus? status,
    required TimetableStatusSettings statusSettings,
  }) {
    final Course c = slot.course;
    final double left = dayWidth * slot.lane / slot.laneCount;
    final double width = dayWidth / slot.laneCount;
    final double top = (c.startPeriod - 1) * rowHeight;
    final int span = (c.endPeriod - c.startPeriod + 1) < 1 ? 1 : (c.endPeriod - c.startPeriod + 1);
    final double height = span * rowHeight;
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
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                CourseFormPage(semester: widget.semester, course: c),
          ),
        ),
        compact: false,
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
}
