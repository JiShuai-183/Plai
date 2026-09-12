import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/holiday.dart';
import 'package:plai/data/models/period.dart';
import 'package:plai/data/models/semester.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:plai/features/timetable/course_form_page.dart';
import 'package:plai/features/timetable/timetable_providers.dart';
import 'package:plai/services/notifications/class_reminder_planner.dart';
import 'package:plai/services/notifications/notification_providers.dart';
import 'package:plai/services/notifications/notification_scheduler.dart';

/// 内存课表仓库：只实现保存流程用到的读写，其余交由 `noSuchMethod` 报错。
class _FakeTimetableRepository implements ITimetableRepository {
  final List<Course> courses = <Course>[];

  @override
  Future<List<Period>> getPeriods() async => const <Period>[];

  @override
  Future<List<Semester>> getSemesters() async => const <Semester>[];

  @override
  Future<List<Course>> getAllCourses() async => courses;

  @override
  Future<List<Course>> getCourses(int semesterId) async => courses;

  @override
  Future<List<Holiday>> getHolidays({
    int? courseId,
    DateTime? from,
    DateTime? to,
  }) async =>
      const <Holiday>[];

  @override
  Future<int> insertCourse(Course course) async {
    courses.add(course);
    return courses.length;
  }

  @override
  Future<int> updateCourse(Course course) async {
    courses.add(course);
    return 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 内存设置仓库：全部键缺省。
class _FakeSettingsRepository implements ISettingsRepository {
  @override
  Future<String?> getValue(String key) async => null;

  @override
  Future<Map<String, String>> getAll() async => const <String, String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 跳过真实通知插件的调度器替身，只记录重排次数。
class _FakeScheduler extends NotificationScheduler {
  _FakeScheduler(super.timetable, super.tasks, super.settings);

  int rescheduleCount = 0;

  @override
  Future<void> rescheduleAll({List<ClassReminderPlan>? classPlans}) async {
    rescheduleCount++;
  }
}

void main() {
  testWidgets('保存课程后先返回课表页，再弹出「课程添加成功」气泡', (WidgetTester tester) async {
    // 高视口让表单（ListView）一次性构建出底部保存按钮，免去滚动。
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _FakeTimetableRepository repo = _FakeTimetableRepository();
    final _FakeSettingsRepository settings = _FakeSettingsRepository();
    final _FakeScheduler scheduler =
        _FakeScheduler(repo, _NoopTaskRepository(), settings);
    // 学期须带 id，否则表单保存会在 semesterId == null 处直接返回。
    final Semester semester = Semester(
      id: 1,
      name: '2026 秋',
      startDate: DateTime(2026, 9, 7),
      totalWeeks: 16,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          timetableRepositoryProvider.overrideWithValue(repo),
          settingsRepositoryProvider.overrideWithValue(settings),
          notificationSchedulerProvider.overrideWithValue(scheduler),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => CourseFormPage(semester: semester),
                    ),
                  ),
                  child: const Text('打开表单'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开表单'));
    await tester.pumpAndSettle();
    expect(find.byType(CourseFormPage), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).first, '高等数学');
    await tester.tap(find.widgetWithText(FilledButton, '添加课程'));
    // 让保存的异步链路跑完（插入 → pop）并推完返回动画（约 300ms）。
    for (int i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(CourseFormPage).evaluate().isEmpty) break;
    }

    expect(repo.courses, hasLength(1));
    // 已回到课表页（表单路由出栈）。
    expect(find.byType(CourseFormPage), findsNothing);
    // 气泡在课表页可见（1s 时长内，此处刚过 400ms）。
    expect(find.text('课程添加成功'), findsOneWidget);
    expect(scheduler.rescheduleCount, 1);

    // 收尾：跑完气泡动画，避免残留计时器。
    await tester.pumpAndSettle();
    expect(find.text('课程添加成功'), findsNothing);
  });
}

/// 无操作任务仓库：`rescheduleTimetableReminders` 不读取任务。
class _NoopTaskRepository implements ITaskRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
