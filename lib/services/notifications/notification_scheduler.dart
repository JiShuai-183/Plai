import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    as fln;
import 'package:timezone/timezone.dart' as tz;

import '../../data/models/course.dart';
import '../../data/models/date_utils.dart';
import '../../data/models/holiday.dart';
import '../../data/models/period.dart';
import '../../data/models/semester.dart';
import '../../data/models/task.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/task_repository.dart';
import '../../data/repositories/timetable_repository.dart';
import 'class_reminder_planner.dart';
import 'notification_ids.dart';
import 'notification_payload.dart';
import 'notification_service.dart';

/// 通知相关设置键（与设置模块共享，字面量不得随意改动）。
///
/// 设置模块读写这几个键即可联动提醒调度：
/// - [enabled]：通知总开关（'true' / 'false'），缺省视为开启；
/// - [classAdvanceMin]：上课提醒提前量（分钟，如 '10'）；
/// - [classVibrate] / [taskVibrate]：课程 / 日程提醒是否震动（'true' / 'false'，
///   默认不震动；调度时据此选择通知渠道）；
/// - [completeSound]：日程完成提示音的本地音频路径（空 = 不播放）；
/// - [keepAliveGuideShown]：国内 ROM 保活引导页是否已展示过（'true' / 'false'）。
abstract final class NotificationSettingsKeys {
  /// 通知总开关设置键。
  static const String enabled = 'notify.enabled';

  /// 上课提醒提前量（分钟）设置键。
  static const String classAdvanceMin = 'notify.class_advance_min';

  /// 课程提醒震动开关设置键（默认不震动）。
  static const String classVibrate = 'notify.class_vibrate';

  /// 日程提醒震动开关设置键（默认不震动）。
  static const String taskVibrate = 'notify.task_vibrate';

  /// 日程完成提示音本地音频路径设置键（空 = 不播放）。
  static const String completeSound = 'notify.complete_sound';

  /// 保活引导页是否已展示设置键。
  static const String keepAliveGuideShown = 'notify.keep_alive_guide_shown';

  /// 上课提醒默认提前分钟数（设置未配置时兜底）。
  static const int defaultClassAdvanceMin = 10;
}

/// 提醒调度器：timetable / schedule / settings 模块的统一调度入口。
///
/// - 上课提醒：接收**具体日期**（由课表模块算好「哪几周有课」后逐次调用）；
/// - 任务提醒：接收 [Task]，内部根据 `remindOffsetMin` / `remindDate` 计算触发时刻；
/// - 全量重排 / 取消：数据变更、通知开关切换时调用。
///
/// 本类不提供 `weekOfDate` / `hasClass`（周次规则归课表模块）。
class NotificationScheduler {
  NotificationScheduler(
    this._timetable,
    this._tasks,
    this._settings, {
    NotificationService? service,
  }) : _service = service ?? NotificationService.instance;

  final ITimetableRepository _timetable;
  final ITaskRepository _tasks;
  final ISettingsRepository _settings;
  final NotificationService _service;

  // ------------------------------------------------------------ 上课提醒

  /// 调度一次上课提醒（单次）。
  ///
  /// - [course]：课程；
  /// - [date]：上课日期（仅年月日，具体到天）；
  /// - [time]：上课时刻（节次开始时间）；
  /// - [advanceMin]：提前提醒分钟数（≥0，来自设置的提前量）；
  /// - [week]：第几周（通知 ID 稳定 + 点击通知定位课表周）；
  /// - [vibrate]：是否震动（选通知渠道）；null = 内部读「课程提醒震动」设置。
  ///
  /// 触发时刻 = date + time - advanceMin；已过期则自动跳过（不调度）。
  /// 同一课程同一周重复调用会覆盖旧通知（同 ID）。
  Future<void> scheduleClassReminder({
    required Course course,
    required DateTime date,
    required TimeOfDay time,
    required int advanceMin,
    required int week,
    bool? vibrate,
  }) async {
    await _service.initialize();
    final int? courseId = course.id;
    if (courseId == null) return; // 未入库课程（无主键）无法调度

    final DateTime remindAt =
        _combine(date, time).subtract(Duration(minutes: advanceMin));
    if (!remindAt.isAfter(DateTime.now())) return; // 已过期

    final bool vib = vibrate ??
        await _settings.getValue(NotificationSettingsKeys.classVibrate) ==
            'true';
    await _schedule(
      id: NotificationIds.classReminderId(courseId, week),
      title: '${course.name} · 上课提醒',
      body: _classBody(course, date, time, week, advanceMin),
      remindAt: remindAt,
      payload: NotificationPayload.classReminder(courseId, week),
      channelId:
          vib ? NotificationIds.vibrateChannelId : NotificationIds.defaultChannelId,
    );
  }

  // ------------------------------------------------------------ 任务提醒

  /// 调度任务 / 定点日程提醒。
  ///
  /// 触发时刻计算规则（优先级从高到低）：
  /// 1. [Task.remindDate] 已冗余存储 → 直接采用；
  /// 2. 否则 = `dueDate + dueTime` 减去 `remindOffsetMin` 分钟
  ///    （`-1` 表示准时触发，`null` 表示不提醒）。
  ///
  /// - [vibrate]：是否震动（选通知渠道）；null = 内部读「日程提醒震动」设置。
  ///
  /// 已完成 / 不提醒 / 已过期 → 取消对应通知（保证重排后一致）。
  Future<void> scheduleTaskReminder(Task task, {bool? vibrate}) async {
    await _service.initialize();
    final int? taskId = task.id;
    if (taskId == null) return;

    final int id = NotificationIds.taskReminderId(taskId);
    if (task.completed || task.remindOffsetMin == null) {
      await _service.plugin.cancel(id: id);
      return;
    }

    final DateTime? remindAt = _taskRemindAt(task);
    if (remindAt == null || !remindAt.isAfter(DateTime.now())) {
      await _service.plugin.cancel(id: id);
      return;
    }

    final bool vib = vibrate ??
        await _settings.getValue(NotificationSettingsKeys.taskVibrate) == 'true';
    await _schedule(
      id: id,
      title: task.title,
      body: _taskBody(task),
      remindAt: remindAt,
      payload: NotificationPayload.taskReminder(taskId),
      channelId:
          vib ? NotificationIds.vibrateChannelId : NotificationIds.defaultChannelId,
    );
  }

  // ------------------------------------------------------------ 取消

  /// 取消某个课程 / 某个任务的全部提醒（数据变更时调用）。
  ///
  /// - 传 [courseId]：取消该课程全部周次的上课提醒；
  /// - 传 [taskId]：取消该任务的提醒。
  /// 通过遍历「待触发通知」按 payload 匹配，不依赖周次推算。
  Future<void> cancelAllRemindersFor({int? courseId, int? taskId}) async {
    await _service.initialize();
    final List<fln.PendingNotificationRequest> pending =
        await _service.plugin.pendingNotificationRequests();
    for (final fln.PendingNotificationRequest req in pending) {
      final NotificationIntent? intent = NotificationPayload.parse(req.payload);
      if (intent == null) continue;
      final bool matchCourse = courseId != null &&
          intent.type == NotificationIntentType.classReminder &&
          intent.courseId == courseId;
      final bool matchTask = taskId != null &&
          intent.type == NotificationIntentType.taskReminder &&
          intent.taskId == taskId;
      if (matchCourse || matchTask) {
        await _service.plugin.cancel(id: req.id);
      }
    }
  }

  /// 取消全部提醒（通知开关关闭 / 数据整体变更前调用）。
  Future<void> cancelAll() async {
    await _service.initialize();
    await _service.plugin.cancelAll();
  }

  // ------------------------------------------------------------ 全量重排

  /// 全量重建提醒（学期 / 课程 / 任务 / 节次时间表 / 设置改动后调用）。
  ///
  /// 流程：取消全部 → 读设置（总开关、提前量）→ 重排任务 → 重排课程。
  /// - 总开关关闭（[NotificationSettingsKeys.enabled] == 'false'）则只取消不重排；
  /// - [classPlans] 可传入课表模块算好的具体计划列表（跳过内部周次展开）；
  ///   缺省时按学期/节次/停课数据内部展开（见 [ClassReminderPlanner]）。
  Future<void> rescheduleAll({List<ClassReminderPlan>? classPlans}) async {
    await _service.initialize();
    await cancelAll();

    final Map<String, String> allSettings = await _settings.getAll();
    if (allSettings[NotificationSettingsKeys.enabled] == 'false') return;

    final int advanceMin =
        int.tryParse(allSettings[NotificationSettingsKeys.classAdvanceMin] ??
                '') ??
            NotificationSettingsKeys.defaultClassAdvanceMin;
    // 震动开关批量读取一次（逐条调度不再查库）。
    final bool classVib =
        allSettings[NotificationSettingsKeys.classVibrate] == 'true';
    final bool taskVib =
        allSettings[NotificationSettingsKeys.taskVibrate] == 'true';

    // 任务
    final List<Task> tasks = await _tasks.getTasks(completed: false);
    for (final Task task in tasks) {
      await scheduleTaskReminder(task, vibrate: taskVib);
    }

    // 课程
    if (classPlans != null) {
      for (final ClassReminderPlan plan in classPlans) {
        await scheduleClassReminder(
          course: plan.course,
          date: plan.date,
          time: plan.startTime,
          advanceMin: plan.advanceMin ?? advanceMin,
          week: plan.week,
          vibrate: classVib,
        );
      }
      return;
    }

    final List<Semester> semesters = await _timetable.getSemesters();
    final List<Course> courses = await _timetable.getAllCourses();
    final List<Period> periods = await _timetable.getPeriods();
    final List<Holiday> holidays = await _timetable.getHolidays();

    for (final Course course in courses) {
      Semester? semester;
      for (final Semester s in semesters) {
        if (s.id == course.semesterId) {
          semester = s;
          break;
        }
      }
      if (semester == null) continue;

      final List<ClassReminderPlan> plans = ClassReminderPlanner.expand(
        course: course,
        semester: semester,
        periods: periods,
        holidays: holidays,
        advanceMin: advanceMin,
      );
      for (final ClassReminderPlan plan in plans) {
        await scheduleClassReminder(
          course: plan.course,
          date: plan.date,
          time: plan.startTime,
          advanceMin: plan.advanceMin ?? advanceMin,
          week: plan.week,
          vibrate: classVib,
        );
      }
    }
  }

  // ------------------------------------------------------------ 保活引导

  /// 是否需要展示国内 ROM 保活引导页（首次开启提醒时）。
  Future<bool> shouldShowKeepAliveGuide() async {
    final String? value =
        await _settings.getValue(NotificationSettingsKeys.keepAliveGuideShown);
    return value != 'true';
  }

  /// 标记保活引导页已展示。
  Future<void> markKeepAliveGuideShown() =>
      _settings.setValue(NotificationSettingsKeys.keepAliveGuideShown, 'true');

  // ------------------------------------------------------------ 内部实现

  /// 统一调度入口：精确调度，失败时降级为非精确调度。
  ///
  /// [channelId]：按「提醒震动」开关选定的通知渠道。
  Future<void> _schedule({
    required int id,
    required String title,
    required String body,
    required DateTime remindAt,
    required String payload,
    required String channelId,
  }) async {
    final fln.NotificationDetails details = fln.NotificationDetails(
      android: fln.AndroidNotificationDetails(
        channelId,
        channelId == NotificationIds.vibrateChannelId
            ? NotificationIds.vibrateChannelName
            : NotificationIds.defaultChannelName,
        channelDescription:
            channelId == NotificationIds.vibrateChannelId
                ? NotificationIds.vibrateChannelDescription
                : NotificationIds.defaultChannelDescription,
        importance: fln.Importance.high,
        priority: fln.Priority.high,
        // playSound 默认 true，sound 未指定 → 使用系统默认提示音。
      ),
      iOS: fln.DarwinNotificationDetails(),
    );
    final tz.TZDateTime zoned = tz.TZDateTime.from(remindAt, tz.local);

    try {
      await _service.plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: zoned,
        notificationDetails: details,
        androidScheduleMode: fln.AndroidScheduleMode.exactAllowWhileIdle,
        payload: payload,
      );
    } on PlatformException {
      // 未授予 SCHEDULE_EXACT_ALARM 等导致精确调度失败 → 降级为非精确调度。
      await _service.plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: zoned,
        notificationDetails: details,
        androidScheduleMode: fln.AndroidScheduleMode.inexactAllowWhileIdle,
        payload: payload,
      );
    }
  }

  /// 任务提醒触发时刻。
  static DateTime? _taskRemindAt(Task task) {
    if (task.remindDate != null) return task.remindDate;
    final DateTime? due = _combineDueTime(task.dueDate, task.dueTime);
    if (due == null) return null;
    final int offset = task.remindOffsetMin ?? -1;
    if (offset < 0) return due; // -1 = 准时
    return due.subtract(Duration(minutes: offset));
  }

  /// 合并日期与 [TimeOfDay] 为本地 DateTime。
  static DateTime _combine(DateTime date, TimeOfDay time) =>
      DateTime(date.year, date.month, date.day, time.hour, time.minute);

  /// 合并日期与时刻字符串（`HH:mm`）；时刻缺失视为当天 00:00，非法返回 null。
  static DateTime? _combineDueTime(DateTime date, String? time) {
    if (time == null) return DateTime(date.year, date.month, date.day);
    final List<String> parts = time.split(':');
    if (parts.length != 2) return null;
    final int? h = int.tryParse(parts[0]);
    final int? m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return DateTime(date.year, date.month, date.day, h, m);
  }

  /// 上课提醒文案。
  String _classBody(
      Course course, DateTime date, TimeOfDay time, int week, int advanceMin) {
    final String dateStr = dateOnlyToString(date);
    final String timeStr = '${_two(time.hour)}:${_two(time.minute)}';
    final String loc = course.location.isEmpty ? '' : ' · ${course.location}';
    final String advance = advanceMin > 0 ? '（提前 $advanceMin 分钟）' : '';
    return '第 $week 周 ${_weekdayLabel(course.weekday)} $timeStr$loc$advance ｜ $dateStr';
  }

  /// 任务提醒文案。
  String _taskBody(Task task) {
    final String dateStr = dateOnlyToString(task.dueDate);
    final String timeStr = task.dueTime ?? '';
    final String at = timeStr.isEmpty ? '' : ' $timeStr';
    final String prefix =
        task.type == TaskType.scheduled ? '定点日程' : '待办任务';
    final String priority = task.priority == Priority.normal
        ? ''
        : '（${task.priority.label}）';
    return '$prefix$priority · $dateStr$at';
  }

  static String _weekdayLabel(int weekday) {
    const List<String> labels = ['一', '二', '三', '四', '五', '六', '日'];
    return '周${labels[weekday - 1]}';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}
