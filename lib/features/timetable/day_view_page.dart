import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/course.dart';
import '../../data/models/holiday.dart';
import '../../data/models/period.dart';
import '../../data/models/semester.dart';
import 'class_lanes.dart';
import 'color_utils.dart';
import 'course_form_page.dart';
import 'format.dart';
import 'timetable_providers.dart';
import 'week_rules.dart';

/// 日视图：单日节次时间线。
///
/// 展示 [date] 当天有课（周次判定）且非停课的课程，按节次纵向排布，
/// 同时间课程并排。全局停课当天顶部提示原因。
class DayViewPage extends ConsumerWidget {
  const DayViewPage({super.key, required this.semester, required this.date});

  /// 所属学期。
  final Semester semester;

  /// 要展示的日期（仅年月日参与判定）。
  final DateTime date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Course>> coursesAsync = ref.watch(coursesProvider);
    final AsyncValue<List<Period>> periodsAsync = ref.watch(periodsProvider);
    final AsyncValue<List<Holiday>> holidaysAsync =
        ref.watch(holidaysProvider);
    final WeekRules rules = WeekRules(
      semesterStart: semester.startDate,
      totalWeeks: semester.totalWeeks,
    );
    final int week = rules.clampWeek(rules.weekOfDate(date));

    return Scaffold(
      appBar: AppBar(title: Text(formatDateWeekday(date))),
      body: coursesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('课程加载失败')),
        data: (courses) => periodsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => const Center(child: Text('节次加载失败')),
          data: (periods) => holidaysAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const Center(child: Text('停课记录加载失败')),
            data: (holidays) =>
                _buildBody(context, courses, periods, holidays, rules, week),
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
  ) {
    final List<Holiday> globalHolidays =
        holidays.where((h) => h.courseId == null && h.date == date).toList();
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
            c.weekday == date.weekday &&
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
        Expanded(child: _buildTimeline(context, periods, slots)),
      ],
    );
  }

  Widget _buildTimeline(
      BuildContext context, List<Period> periods, List<CourseSlot> slots) {
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
                    for (final CourseSlot slot in slots)
                      _buildCourseBlock(context, slot, dayWidth, rowHeight),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCourseBlock(BuildContext context, CourseSlot slot,
      double dayWidth, double rowHeight) {
    final Course c = slot.course;
    final double left = dayWidth * slot.lane / slot.laneCount;
    final double width = dayWidth / slot.laneCount;
    final double top = (c.startPeriod - 1) * rowHeight;
    final int span = (c.endPeriod - c.startPeriod + 1) < 1 ? 1 : (c.endPeriod - c.startPeriod + 1);
    final double height = span * rowHeight;
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
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => CourseFormPage(semester: semester, course: c),
            ),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
                      fontSize: 12,
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
}
