import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/holiday.dart';
import 'package:plai/data/models/period.dart';
import 'package:plai/data/models/semester.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:plai/features/timetable/timetable_providers.dart';
import 'package:plai/services/notifications/class_reminder_planner.dart';
import 'package:plai/services/notifications/notification_providers.dart';
import 'package:plai/services/notifications/notification_scheduler.dart';

class _Timetable extends Fake implements ITimetableRepository {
  List<Semester> semesters = [
    Semester(id: 1, name: '秋', startDate: DateTime(2026, 9, 1), totalWeeks: 2),
    Semester(id: 2, name: '春', startDate: DateTime(2027, 3, 1), totalWeeks: 2),
  ];
  int reads = 0;

  @override
  Future<List<Semester>> getSemesters() async {
    reads++;
    return semesters;
  }

  @override
  Future<List<Course>> getAllCourses() async {
    reads++;
    return [
      for (final id in [1, 2])
        Course(
          id: id,
          semesterId: id,
          name: '课程$id',
          weekday: 3,
          startPeriod: 1,
          endPeriod: 1,
          weekType: WeekType.every,
          startWeek: 1,
          endWeek: 2,
        ),
    ];
  }

  @override
  Future<List<Period>> getPeriods() async {
    reads++;
    return const [Period(index: 1, startTime: '08:00', endTime: '08:45')];
  }

  @override
  Future<List<Holiday>> getHolidays({
    int? courseId,
    DateTime? from,
    DateTime? to,
  }) async {
    reads++;
    expect([courseId, from, to], everyElement(isNull));
    return [Holiday(date: DateTime(2026, 9, 2))];
  }
}

class _Settings extends Fake implements ISettingsRepository {
  String? advance;

  @override
  Future<String?> getValue(String key) async {
    expect(key, NotificationSettingsKeys.classAdvanceMin);
    return advance;
  }
}

class _Scheduler extends Fake implements NotificationScheduler {
  List<ClassReminderPlan>? plans;
  int calls = 0;
  Object? error;

  @override
  Future<void> rescheduleAll({List<ClassReminderPlan>? classPlans}) async {
    calls++;
    plans = classPlans;
    if (error case final Object failure) throw failure;
  }
}

void main() {
  late _Timetable timetable;
  late _Settings settings;
  late _Scheduler scheduler;
  late ProviderContainer container;

  setUp(() {
    timetable = _Timetable();
    settings = _Settings();
    scheduler = _Scheduler();
    container = ProviderContainer(
      overrides: [
        timetableRepositoryProvider.overrideWithValue(timetable),
        settingsRepositoryProvider.overrideWithValue(settings),
        notificationSchedulerProvider.overrideWithValue(scheduler),
      ],
    );
  });
  tearDown(() => container.dispose());

  test('普通 Ref 无页面重排全部学期，应用停课和提前量', () async {
    settings.advance = '25';
    // 模拟后台 provider：只有普通 Ref，无 WidgetRef / Widget 生命周期。
    final background = Provider<Future<void> Function()>(
      (ref) =>
          () => ref.read(timetableReminderReschedulerProvider)(),
    );
    await container.read(background)();

    expect(timetable.reads, 4);
    expect(scheduler.calls, 1);
    final plans = scheduler.plans!;
    expect(plans.map((p) => p.course.semesterId), [1, 2, 2]);
    expect(plans.map((p) => p.week), [2, 1, 2]);
    expect(plans.map((p) => p.date), [
      DateTime(2026, 9, 9),
      DateTime(2027, 3, 3),
      DateTime(2027, 3, 10),
    ]);
    expect(
      plans.map((p) => p.startTime),
      everyElement(const TimeOfDay(hour: 8, minute: 0)),
    );
    expect(plans.map((p) => p.advanceMin), everyElement(25));
  });

  test('每次执行重新读取提前量，缺失或非法值用默认值', () async {
    final reschedule = container.read(timetableReminderReschedulerProvider);
    for (final value in [null, 'invalid', '0']) {
      settings.advance = value;
      await reschedule();
      expect(
        scheduler.plans!.map((p) => p.advanceMin),
        everyElement(
          value == '0' ? 0 : NotificationSettingsKeys.defaultClassAdvanceMin,
        ),
      );
    }
    expect(scheduler.calls, 3);
    expect(timetable.reads, 12);
  });

  test('没有学期仍提交空计划，调度失败向调用方传播', () async {
    timetable.semesters = [];
    final reschedule = container.read(timetableReminderReschedulerProvider);
    await reschedule();
    expect(scheduler.plans, isEmpty);
    expect(scheduler.calls, 1);

    final failure = StateError('schedule failed');
    scheduler.error = failure;
    await expectLater(reschedule(), throwsA(same(failure)));
  });
}
