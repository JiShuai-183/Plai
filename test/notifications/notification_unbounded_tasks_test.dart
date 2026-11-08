import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    as fln;
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:plai/services/notifications/notification_ids.dart';
import 'package:plai/services/notifications/notification_scheduler.dart';
import 'package:plai/services/notifications/notification_service.dart';
import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

class _Plugin implements fln.FlutterLocalNotificationsPlugin {
  final scheduled = <Invocation>[];
  final cancelled = <Invocation>[];
  @override
  dynamic noSuchMethod(Invocation call) {
    if (call.memberName == #zonedSchedule) {
      scheduled.add(call);
      return Future<void>.value();
    }
    if (call.memberName == #cancel) {
      cancelled.add(call);
      return Future<void>.value();
    }
    throw UnsupportedError('${call.memberName}');
  }
}

class _Service implements NotificationService {
  @override
  final _Plugin plugin = _Plugin();
  @override
  Future<void> initialize() async {}
  @override
  dynamic noSuchMethod(Invocation call) =>
      throw UnsupportedError('${call.memberName}');
}

class _Repos
    implements ITimetableRepository, ITaskRepository, ISettingsRepository {
  @override
  dynamic noSuchMethod(Invocation call) =>
      throw UnsupportedError('${call.memberName}');
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late _Service service;
  late NotificationScheduler scheduler;
  setUp(() {
    service = _Service();
    final repos = _Repos();
    scheduler = NotificationScheduler(repos, repos, repos, service: service);
  });

  test('长期daily无起止日期，今天已过则明天，远期也保持重复', () async {
    final task = Task(
      id: 1,
      title: '背单词',
      type: TaskType.daily,
      dueDate: null,
      dailyRemindTime: '21:30',
    );
    expect(
      NotificationScheduler.dailyRemindFirstAt(
        task,
        '21:30',
        now: DateTime(2030, 1, 1, 10),
      ),
      DateTime(2030, 1, 1, 21, 30),
    );
    expect(
      NotificationScheduler.dailyRemindFirstAt(
        task,
        '21:30',
        now: DateTime(2030, 1, 1, 22),
      ),
      DateTime(2030, 1, 2, 21, 30),
    );
    await scheduler.scheduleTaskReminder(task);
    expect(service.plugin.cancelled, isEmpty);
    expect(
      service.plugin.scheduled.single.namedArguments[#matchDateTimeComponents],
      fln.DateTimeComponents.time,
    );
  });

  test('无期限todo只使用明确每日时刻，不虚构截止日期', () async {
    final task = Task(
      id: 2,
      title: '计划',
      type: TaskType.todo,
      dueDate: null,
      dailyRemindTime: '08:15',
      reminderRepeat: ReminderRepeat.daily,
    );
    await scheduler.scheduleTaskReminder(task);
    final call = service.plugin.scheduled.single;
    expect(
      call.namedArguments[#matchDateTimeComponents],
      fln.DateTimeComponents.time,
    );
    expect(call.namedArguments[#body], '待办任务 · 每天 08:15');
  });

  test('无期限todo独立一次提醒仍可调度，与截止无关', () async {
    final at = DateTime.now().add(const Duration(days: 3));
    await scheduler.scheduleTaskReminder(
      Task(
        id: 3,
        title: '计划',
        type: TaskType.todo,
        dueDate: null,
        reminderRepeat: ReminderRepeat.once,
        remindOnceAt: at,
      ),
    );
    final call = service.plugin.scheduled.single;
    expect(call.namedArguments[#matchDateTimeComponents], isNull);
    expect(
      (call.namedArguments[#scheduledDate] as tz.TZDateTime).isAtSameMomentAs(
        DateTime(at.year, at.month, at.day, at.hour, at.minute),
      ),
      isTrue,
    );
  });

  test('无期限未设提醒，以及残留offset/remindDate，都安全取消而非安排今天', () async {
    for (final task in [
      Task(id: 4, title: '无提醒', type: TaskType.todo, dueDate: null),
      Task(
        id: 4,
        title: '旧offset',
        type: TaskType.todo,
        dueDate: null,
        remindOffsetMin: -1,
        remindDate: DateTime.now().add(const Duration(days: 1)),
      ),
    ]) {
      await scheduler.scheduleTaskReminder(task);
    }
    expect(service.plugin.scheduled, isEmpty);
    expect(service.plugin.cancelled, hasLength(2));
    expect(
      service.plugin.cancelled.last.namedArguments[#id],
      NotificationIds.taskReminderId(4),
    );
  });

  test('已完成无期限todo取消重复提醒，长期daily未设置时刻也不自动提醒', () async {
    await scheduler.scheduleTaskReminder(
      Task(
        id: 5,
        title: '已完成',
        type: TaskType.todo,
        dueDate: null,
        completed: true,
        dailyRemindTime: '10:00',
      ),
    );
    await scheduler.scheduleTaskReminder(
      Task(id: 6, title: '长期', type: TaskType.daily, dueDate: null),
    );
    expect(service.plugin.scheduled, isEmpty);
    expect(service.plugin.cancelled, hasLength(2));
  });

  test('旧有截止daily结束后不调度，定时日程offset仍调度原定日期', () async {
    final ended = Task(
      id: 7,
      title: '结束',
      type: TaskType.daily,
      startDate: DateTime(2020, 1, 1),
      dueDate: DateTime(2020, 1, 3),
      dailyRemindTime: '21:30',
    );
    await scheduler.scheduleTaskReminder(ended);
    expect(service.plugin.cancelled, hasLength(1));
    final due = DateTime.now().add(const Duration(days: 2));
    await scheduler.scheduleTaskReminder(
      Task(
        id: 8,
        title: '定时',
        type: TaskType.scheduled,
        dueDate: due,
        dueTime: '14:00',
        remindOffsetMin: 30,
      ),
    );
    expect(
      (service.plugin.scheduled.single.namedArguments[#scheduledDate]
              as tz.TZDateTime)
          .isAtSameMomentAs(DateTime(due.year, due.month, due.day, 13, 30)),
      isTrue,
    );
  });
}
