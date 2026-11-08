import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

class _Service implements NotificationService {
  @override
  final plugin = fln.FlutterLocalNotificationsPlugin();
  @override
  Future<void> initialize() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Repos
    implements ITaskRepository, ISettingsRepository, ITimetableRepository {
  final logs = <DateTime>[];
  List<Task> tasks = [];
  String? enabled;
  bool failLogs = false;
  @override
  Future<List<DateTime>> dailyLogsFor(int taskId) async {
    if (failLogs) throw StateError('日志读取失败');
    return logs;
  }

  @override
  Future<bool> isDailyCompleted(int taskId, DateTime date) async => logs.any(
    (d) => d.year == date.year && d.month == date.month && d.day == date.day,
  );

  @override
  Future<String?> getValue(String key) async => enabled;
  @override
  Future<Map<String, String>> getAll() async => {
    NotificationSettingsKeys.enabled: ?enabled,
  };
  @override
  Future<List<Task>> getTasks({
    TaskType? type,
    bool? completed,
    DateTime? from,
    DateTime? to,
  }) async => tasks;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final calls = <MethodCall>[];
  final now = DateTime(2030, 1, 2, 10);
  late _Repos repos;
  late NotificationScheduler scheduler;
  bool failCancel = false;
  bool failExact = false;
  Completer<void>? blockedExact;
  Completer<void>? exactEntered;
  setUpAll(tzdata.initializeTimeZones);
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    fln.AndroidFlutterLocalNotificationsPlugin.registerWith();
    repos = _Repos();
    calls.clear();
    failCancel = false;
    failExact = false;
    blockedExact = null;
    exactEntered = null;
    scheduler = NotificationScheduler(
      repos,
      repos,
      repos,
      service: _Service(),
      now: () => now,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'zonedSchedule' &&
              blockedExact != null &&
              (call.arguments['platformSpecifics'] as Map)['scheduleMode'] ==
                  'exactAllowWhileIdle') {
            exactEntered!.complete();
            final wait = blockedExact!;
            blockedExact = null;
            await wait.future;
            throw PlatformException(code: 'exact_alarms_not_permitted');
          }
          if (call.method == 'cancel' && failCancel) {
            throw PlatformException(code: 'cancel_failed');
          }
          if (call.method == 'zonedSchedule' &&
              failExact &&
              (call.arguments['platformSpecifics'] as Map)['scheduleMode'] ==
                  'exactAllowWhileIdle') {
            throw PlatformException(code: 'exact_alarms_not_permitted');
          }
          return null;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  Task daily({DateTime? start, DateTime? end}) => Task(
    id: 11,
    title: '打卡',
    type: TaskType.daily,
    startDate: start,
    dueDate: end,
    dailyRemindTime: '18:30',
  );
  List<MethodCall> scheduled() =>
      calls.where((c) => c.method == 'zonedSchedule').toList();
  void expectDay(int day) {
    final args = scheduled().last.arguments as Map;
    final expected = tz.TZDateTime.from(
      DateTime(2030, 1, day, 18, 30),
      tz.local,
    );
    expect(args['scheduledDateTimeISO8601'], expected.toIso8601String());
    expect(args['scheduledNotificationRepeatFrequency'], 0);
    expect(
      args.containsKey('matchDateTimeComponents'),
      isFalse,
      reason: 'time 会使Android原生丢弃日期并排回今天',
    );
    expect(args['id'], NotificationIds.taskReminderId(11));
    expect(calls.first.method, 'cancel');
  }

  test('未打卡今天正常提醒；已打卡今天从明天开始无限重复', () async {
    final task = daily();
    await scheduler.scheduleTaskReminder(task);
    expectDay(2);
    repos.logs.add(DateTime(2030, 1, 2, 22));
    calls.clear();
    await scheduler.scheduleTaskReminder(task);
    expectDay(3);
  });
  test('取消今天打卡后恢复今天未到时刻', () async {
    repos.logs.add(now);
    await scheduler.scheduleTaskReminder(daily());
    expectDay(3);
    repos.logs.clear();
    calls.clear();
    await scheduler.scheduleTaskReminder(daily());
    expectDay(2);
  });
  test('未来预打卡不抑制今天，未来区间起点已打卡则跳下一天', () async {
    repos.logs.add(DateTime(2030, 1, 4));
    await scheduler.scheduleTaskReminder(daily());
    expectDay(2);
    calls.clear();
    await scheduler.scheduleTaskReminder(daily(start: DateTime(2030, 1, 4)));
    expectDay(5);
  });
  test('最后一天已打卡只取消，未打卡仍保留当天', () async {
    final task = daily(start: DateTime(2030, 1, 1), end: now);
    await scheduler.scheduleTaskReminder(task);
    expectDay(2);
    calls.clear();
    repos.logs.add(now);
    await scheduler.scheduleTaskReminder(task);
    expect(scheduled(), isEmpty);
    expect(calls.single.method, 'cancel');
  });
  test('全量重排读取真实日志，不恢复当天已完成提醒', () async {
    repos.tasks = [daily()];
    repos.logs.add(now);
    await scheduler.rescheduleAll(classPlans: []);
    expect(calls.first.method, 'cancelAll');
    calls.removeAt(0);
    expectDay(3);
  });
  test('通知开关关闭只取消，不因重新打卡开启通知', () async {
    repos.enabled = 'false';
    await scheduler.scheduleTaskReminder(daily());
    expect(calls.single.method, 'cancel');
  });
  test('日志读取失败保留取消结果并上抛，取消失败也不假成功', () async {
    repos.failLogs = true;
    await expectLater(
      scheduler.scheduleTaskReminder(daily()),
      throwsStateError,
    );
    expect(calls.single.method, 'cancel');
    failCancel = true;
    await expectLater(
      scheduler.scheduleTaskReminder(daily()),
      throwsA(isA<PlatformException>()),
    );
    expect(scheduled(), isEmpty);
  });
  test('精确闹钟失败降级仍保留明日起点与原生Daily标识', () async {
    repos.logs.add(now);
    failExact = true;
    await scheduler.scheduleTaskReminder(daily());
    expect(scheduled(), hasLength(2));
    expectDay(3);
    expect(
      (scheduled().last.arguments['platformSpecifics'] as Map)['scheduleMode'],
      'inexactAllowWhileIdle',
    );
  });
  test('Android适配的渠道声音等wire与插件公共序列化一致', () async {
    await scheduler.scheduleTaskReminder(daily());
    final adapted = Map<Object?, Object?>.from(
      scheduled().single.arguments as Map,
    );
    final details = fln.AndroidNotificationDetails(
      NotificationIds.taskChannelId,
      NotificationIds.channelMetaOf(NotificationIds.taskChannelId).name,
      channelDescription: NotificationIds.channelMetaOf(
        NotificationIds.taskChannelId,
      ).description,
      importance: fln.Importance.high,
      priority: fln.Priority.high,
      playSound: true,
    );
    await _Service().plugin.zonedSchedule(
      id: adapted['id']! as int,
      title: adapted['title'] as String?,
      body: adapted['body'] as String?,
      scheduledDate: tz.TZDateTime.from(DateTime(2030, 1, 2, 18, 30), tz.local),
      notificationDetails: fln.NotificationDetails(android: details),
      payload: adapted['payload'] as String?,
      androidScheduleMode: fln.AndroidScheduleMode.exactAllowWhileIdle,
    );
    adapted.remove('scheduledNotificationRepeatFrequency');
    expect(adapted, scheduled().last.arguments);
  });
  test('iOS跳过今天不伪装支持无限延后重复，取消后明确报错', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    fln.IOSFlutterLocalNotificationsPlugin.registerWith();
    repos.logs.add(now);
    await expectLater(
      scheduler.scheduleTaskReminder(daily()),
      throwsUnsupportedError,
    );
    expect(calls.single.method, 'cancel');
  });
  test('同任务并发重排串行，旧调度降级不能覆盖新打卡取消', () async {
    final gate = Completer<void>();
    blockedExact = gate;
    exactEntered = Completer<void>();
    final old = scheduler.scheduleTaskReminder(daily());
    await exactEntered!.future;
    repos.logs.add(now);
    final updated = scheduler.scheduleTaskReminder(daily());
    gate.complete();
    await Future.wait([old, updated]);
    expect(scheduled(), hasLength(3));
    expectDay(3);
    expect(calls.map((c) => c.method), [
      'cancel',
      'zonedSchedule',
      'zonedSchedule',
      'cancel',
      'zonedSchedule',
    ]);
  });
  test('daily单次只取消该提醒自然日，不把今天打卡误用于明日单次', () async {
    final todayOnce = daily().copyWith(
      reminderRepeat: ReminderRepeat.once,
      remindOnceAt: DateTime(2030, 1, 2, 18, 30),
    );
    repos.logs.add(now);
    await scheduler.scheduleTaskReminder(todayOnce);
    expect(calls.single.method, 'cancel');
    calls.clear();
    await scheduler.scheduleTaskReminder(
      todayOnce.copyWith(remindOnceAt: DateTime(2030, 1, 3, 18, 30)),
    );
    final args = scheduled().single.arguments as Map;
    expect(args.containsKey('matchDateTimeComponents'), isFalse);
    expect(args.containsKey('scheduledNotificationRepeatFrequency'), isFalse);
    expect(
      args['scheduledDateTimeISO8601'],
      tz.TZDateTime.from(
        DateTime(2030, 1, 3, 18, 30),
        tz.local,
      ).toIso8601String(),
    );
    calls.clear();
    repos.logs.add(DateTime(2030, 1, 3));
    await scheduler.scheduleTaskReminder(
      todayOnce.copyWith(remindOnceAt: DateTime(2030, 1, 3, 18, 30)),
    );
    expect(calls.single.method, 'cancel');
  });
  test('daily单次总开关关闭不调度', () async {
    repos.enabled = 'false';
    await scheduler.scheduleTaskReminder(
      daily().copyWith(
        reminderRepeat: ReminderRepeat.once,
        remindOnceAt: DateTime(2030, 1, 3, 18, 30),
      ),
    );
    expect(calls.single.method, 'cancel');
  });
}
