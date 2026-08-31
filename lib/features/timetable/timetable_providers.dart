import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/app_database.dart';
import '../../data/db/default_periods.dart';
import '../../data/import_export/timetable_import_export.dart';
import '../../data/models/course.dart';
import '../../data/models/holiday.dart';
import '../../data/models/period.dart';
import '../../data/models/semester.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/timetable_repository.dart';
import '../../services/notifications/class_reminder_planner.dart';
import '../../services/notifications/notification_providers.dart';
import '../../services/notifications/notification_scheduler.dart';
import 'reminder_planner.dart';

/// 课表数据仓库（feature 依赖数据层接口，实现由 plai-data 提供）。
final timetableRepositoryProvider = Provider<ITimetableRepository>(
  (ref) => TimetableRepository(AppDatabase.instance),
);

/// 设置仓库（读上课提醒提前量等键）。
final settingsRepositoryProvider = Provider<ISettingsRepository>(
  (ref) => SettingsRepository(AppDatabase.instance),
);

/// 课表 JSON/CSV 导入导出工具（数据层）。
final timetableImportExportProvider = Provider<TimetableImportExport>(
  (ref) => TimetableImportExport(
    db: AppDatabase.instance,
    timetable: ref.watch(timetableRepositoryProvider),
  ),
);

/// 当前选中学期 id；null 表示自动使用最新学期。
final currentSemesterIdProvider = StateProvider<int?>((ref) => null);

/// 全部学期（按开学日期倒序）。
final semestersProvider = FutureProvider<List<Semester>>(
  (ref) => ref.watch(timetableRepositoryProvider).getSemesters(),
);

/// 当前生效学期：优先手动选中，缺省取最新学期；无学期时为 null。
final currentSemesterProvider = FutureProvider<Semester?>((ref) async {
  final int? selected = ref.watch(currentSemesterIdProvider);
  final List<Semester> semesters =
      await ref.watch(semestersProvider.future);
  if (selected != null) {
    for (final Semester s in semesters) {
      if (s.id == selected) return s;
    }
  }
  return semesters.isEmpty ? null : semesters.first;
});

/// 当前学期全部课程（按星期、起始节次排序）。
final coursesProvider = FutureProvider<List<Course>>((ref) async {
  final ITimetableRepository repo = ref.watch(timetableRepositoryProvider);
  final Semester? semester = await ref.watch(currentSemesterProvider.future);
  final int? id = semester?.id;
  if (id == null) return const <Course>[];
  return repo.getCourses(id);
});

/// 节次时间表（按序号排序）。
final periodsProvider = FutureProvider<List<Period>>(
  (ref) => ref.watch(timetableRepositoryProvider).getPeriods(),
);

/// 当前学期日期范围内的停课记录。
final holidaysProvider = FutureProvider<List<Holiday>>((ref) async {
  final ITimetableRepository repo = ref.watch(timetableRepositoryProvider);
  final Semester? semester = await ref.watch(currentSemesterProvider.future);
  if (semester == null) return const <Holiday>[];
  return repo.getHolidays(from: semester.startDate, to: semester.endDate);
});

/// 上课提醒提前量（分钟），来自设置键，缺省 [NotificationSettingsKeys.defaultClassAdvanceMin]。
final classAdvanceMinProvider = FutureProvider<int>((ref) async {
  final String? value = await ref
      .watch(settingsRepositoryProvider)
      .getValue(NotificationSettingsKeys.classAdvanceMin);
  return int.tryParse(value ?? '') ??
      NotificationSettingsKeys.defaultClassAdvanceMin;
});

/// 节次表为空时写入内置国内高校模板（首次启动兜底）。
///
/// 数据层不自动写入，由本模块在进入课表页时检测并插入。
Future<void> ensureDefaultPeriods(WidgetRef ref) async {
  try {
    final ITimetableRepository repo = ref.read(timetableRepositoryProvider);
    if ((await repo.getPeriods()).isEmpty) {
      await repo.replacePeriods(defaultPeriods);
      ref.invalidate(periodsProvider);
    }
  } catch (_) {
    // 平台数据库不可用（如宿主 widget 测试）时静默，不阻断页面。
  }
}

/// 重新调度全部上课提醒（课程/学期/节次/导入改动后调用）。
///
/// 用本模块周次引擎算出具体计划传入 [NotificationScheduler.rescheduleAll]，
/// 跳过 notify 模块的内部展开，保证周次/停课规则以课表模块为准。
Future<void> rescheduleTimetableReminders(WidgetRef ref) async {
  final ITimetableRepository repo = ref.read(timetableRepositoryProvider);
  final ISettingsRepository settings = ref.read(settingsRepositoryProvider);
  final String? rawAdvance =
      await settings.getValue(NotificationSettingsKeys.classAdvanceMin);
  final int advanceMin = int.tryParse(rawAdvance ?? '') ??
      NotificationSettingsKeys.defaultClassAdvanceMin;

  final List<Semester> semesters = await repo.getSemesters();
  final List<Course> courses = await repo.getAllCourses();
  final List<Period> periods = await repo.getPeriods();
  final List<Holiday> holidays = await repo.getHolidays();

  final List<ClassReminderPlan> plans = <ClassReminderPlan>[];
  for (final Semester semester in semesters) {
    final List<Course> semesterCourses =
        courses.where((c) => c.semesterId == semester.id).toList();
    plans.addAll(buildClassReminderPlans(
      semester: semester,
      courses: semesterCourses,
      periods: periods,
      holidays: holidays,
      advanceMin: advanceMin,
    ));
  }
  final NotificationScheduler scheduler =
      ref.read(notificationSchedulerProvider);
  await scheduler.rescheduleAll(classPlans: plans);
}
