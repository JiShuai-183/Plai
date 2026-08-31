import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/app_database.dart';
import '../../data/models/course.dart';
import '../../data/models/holiday.dart';
import '../../data/models/period.dart';
import '../../data/models/semester.dart';
import '../../data/models/task.dart';
import '../../data/repositories/task_repository.dart';
import '../timetable/timetable_providers.dart';
import '../timetable/week_rules.dart';
import '../../services/notifications/notification_providers.dart';

/// 日程任务数据仓库（feature 依赖数据层接口，禁止直接写库）。
final taskRepositoryProvider = Provider<ITaskRepository>(
  (ref) => TaskRepository(AppDatabase.instance),
);

/// 全部任务（含已完成）。今日 / 列表 / 日历页在内存中按需分组过滤。
///
/// 数据变化（增删改 / 打卡）时通过 `ref.invalidate(tasksProvider)` 刷新。
final tasksProvider = FutureProvider<List<Task>>(
  (ref) => ref.watch(taskRepositoryProvider).getTasks(),
);

/// 按 id 查询单个任务（任务详情页 / 通知深链用）。
final taskByIdProvider = FutureProvider.family<Task?, int>(
  (ref, id) => ref.watch(taskRepositoryProvider).getTaskById(id),
);

/// 按 id 查询课程（任务详情页显示关联课程名）。
final courseByIdProvider = FutureProvider.family<Course?, int>(
  (ref, id) => ref.watch(timetableRepositoryProvider).getCourseById(id),
);

/// 全部学期课程（任务表单「关联课程」下拉用，读课表模块仓库接口）。
final allCoursesProvider = FutureProvider<List<Course>>((ref) async {
  final List<Course> courses =
      await ref.watch(timetableRepositoryProvider).getAllCourses();
  courses.sort((Course a, Course b) {
    final int semester = a.semesterId.compareTo(b.semesterId);
    return semester != 0 ? semester : a.name.compareTo(b.name);
  });
  return courses;
});

/// 课程下拉选项 `(id, 展示名)`，展示名带学期名消歧。
final courseOptionsProvider = FutureProvider<List<(int, String)>>((ref) async {
  final List<Course> courses = await ref.watch(allCoursesProvider.future);
  final List<Semester> semesters = await ref.watch(semestersProvider.future);
  final Map<int, String> semesterNames = <int, String>{
    for (final Semester s in semesters)
      if (s.id != null) s.id!: s.name,
  };
  return <(int, String)>[
    for (final Course c in courses)
      if (c.id != null)
        (
          c.id!,
          semesterNames[c.semesterId] == null
              ? c.name
              : '${c.name}（${semesterNames[c.semesterId]}）',
        ),
  ];
});

/// 今日有课课程的展示数据。
class TodayCourse {
  const TodayCourse({
    required this.course,
    required this.week,
    this.startTime,
    this.endTime,
  });

  /// 今日有课的课程。
  final Course course;

  /// 当周周次。
  final int week;

  /// 起始节次的开始时刻（节次表缺失时为 null）。
  final TimeOfDay? startTime;

  /// 结束节次的结束时刻（节次表缺失时为 null）。
  final TimeOfDay? endTime;
}

/// 今日视图聚合数据：今日课程 + 全部任务。
class TodayView {
  const TodayView({required this.courses, required this.tasks});

  /// 今日有课课程（周次/停课过滤后）。
  final List<TodayCourse> courses;

  /// 全部任务（页面按「已逾期 / 今日 / 已完成」分组展示）。
  final List<Task> tasks;
}

/// 今日视图数据源。
final todayViewProvider = FutureProvider<TodayView>((ref) async {
  final List<TodayCourse> courses = await ref.watch(todayCoursesProvider.future);
  final List<Task> tasks = await ref.watch(tasksProvider.future);
  return TodayView(courses: courses, tasks: tasks);
});

/// 今日有课的课程：取当前学期课程，用周次规则 + 停课过滤。
///
/// 只读复用课表模块的数据与 [WeekRules]，不修改课表模块任何文件。
final todayCoursesProvider = FutureProvider<List<TodayCourse>>((ref) async {
  final Semester? semester = await ref.watch(currentSemesterProvider.future);
  if (semester == null) return const <TodayCourse>[];
  final List<Course> courses = await ref.watch(coursesProvider.future);
  final List<Holiday> holidays = await ref.watch(holidaysProvider.future);
  final List<Period> periods = await ref.watch(periodsProvider.future);

  final DateTime today = _dateOnly(DateTime.now());
  // 学期外（开学前 / 结课后）不展示「今日课程」，避免把未来/历史周的课误标为今天。
  if (today.isBefore(semester.startDate) || today.isAfter(semester.endDate)) {
    return const <TodayCourse>[];
  }
  final WeekRules rules = WeekRules(
    semesterStart: semester.startDate,
    totalWeeks: semester.totalWeeks,
  );
  final int week = rules.clampWeek(rules.weekOfDate(today));

  final List<TodayCourse> result = <TodayCourse>[];
  for (final Course c in courses) {
    if (c.weekday != today.weekday) continue;
    if (!WeekRules.hasClass(c, week)) continue;
    if (rules.isCourseHoliday(c, week, holidays: holidays)) continue;
    result.add(TodayCourse(
      course: c,
      week: week,
      startTime: _periodTime(c.startPeriod, periods, end: false),
      endTime: _periodTime(c.endPeriod, periods, end: true),
    ));
  }
  result.sort(
      (TodayCourse a, TodayCourse b) => a.course.startPeriod.compareTo(b.course.startPeriod));
  return result;
});

/// 完成 / 取消打卡，并同步提醒调度（完成 → 取消提醒，取消 → 恢复提醒）。
Future<void> toggleTaskCompleted(WidgetRef ref, Task task) async {
  final int? id = task.id;
  if (id == null) return;
  final ITaskRepository repo = ref.read(taskRepositoryProvider);
  await repo.setCompleted(id, !task.completed);
  final Task? updated = await repo.getTaskById(id);
  if (updated != null) {
    await ref
        .read(notificationSchedulerProvider)
        .scheduleTaskReminder(updated);
  }
  ref.invalidate(tasksProvider);
  ref.invalidate(taskByIdProvider(id));
}

/// 保存任务（新建或更新），并同步提醒调度（同 id 覆盖 / 不提醒则取消）。
Future<int?> saveTask(WidgetRef ref, Task task) async {
  final ITaskRepository repo = ref.read(taskRepositoryProvider);
  final int? id = task.id;
  final int newId;
  if (id == null) {
    newId = await repo.insertTask(task);
  } else {
    await repo.updateTask(task);
    newId = id;
  }
  final Task? saved = await repo.getTaskById(newId);
  if (saved != null) {
    await ref
        .read(notificationSchedulerProvider)
        .scheduleTaskReminder(saved);
  }
  ref.invalidate(tasksProvider);
  if (id != null) ref.invalidate(taskByIdProvider(id));
  return newId;
}

/// 删除任务，并取消对应任务提醒。
Future<void> deleteTask(WidgetRef ref, int id) async {
  await ref.read(taskRepositoryProvider).deleteTask(id);
  await ref
      .read(notificationSchedulerProvider)
      .cancelAllRemindersFor(taskId: id);
  ref.invalidate(tasksProvider);
  ref.invalidate(taskByIdProvider(id));
}

/// 节次表中指定序号的开始 / 结束时刻；缺失返回 null。
TimeOfDay? _periodTime(int index, List<Period> periods, {required bool end}) {
  for (final Period p in periods) {
    if (p.index != index) continue;
    final String raw = end ? p.endTime : p.startTime;
    final List<String> parts = raw.split(':');
    if (parts.length != 2) return null;
    final int? h = int.tryParse(parts[0]);
    final int? m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h, minute: m);
  }
  return null;
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
