import 'dart:typed_data';

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

  /// 震动通知的显式节拍（0 停 → 300ms 震 → 200 停 → 300 震）。
  ///
  /// 部分 ROM 对「渠道默认震动」支持不稳，显式 pattern 在送达时强制
  /// `builder.setVibrate`，保证震动不依赖渠道默认值。
  static final Int64List _vibrationPattern =
      Int64List.fromList([0, 300, 200, 300]);

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

  /// 调度任务的每日重复提醒；存量单次 offset 提醒（旧版 UI）仍兼容调度。
  ///
  /// **每日重复提醒（所有类型统一）**：设了 [Task.dailyRemindTime] → 每天同一
  /// 时刻一条重复通知（首次触发见 [dailyRemindFirstAt]，之后系统按时每日重发）；
  /// 未设 / 已完成 / 区间已结束 → 取消该任务通知。
  /// - daily / span（区间型）：起止区间内每天重复；
  /// - todo / scheduled：从今天起每天重复，直到勾完成（completed 分支取消）。
  /// 注：重复通知系统不会在截止日自动停发，靠下次本任务/全量重排顺带清理。
  ///
  /// **存量单次提醒兼容**：旧版 scheduled / todo 曾配过 remindOffsetMin /
  /// remindDate，若未设每日提醒，仍按单次触发（触发时刻见 [_taskRemindAt]），
  /// 老数据不丢提醒。
  ///
  /// - [vibrate]：是否震动（选通知渠道）；null = 内部读「日程提醒震动」设置。
  Future<void> scheduleTaskReminder(Task task, {bool? vibrate}) async {
    await _service.initialize();
    final int? taskId = task.id;
    if (taskId == null) return;

    final int id = NotificationIds.taskReminderId(taskId);
    if (task.completed) {
      await _service.plugin.cancel(id: id);
      return;
    }
    if (task.dailyRemindTime != null) {
      await _scheduleDailyRepeat(task, id, vibrate: vibrate);
      return;
    }
    // 存量单次提醒（旧版 scheduled/todo 提前量 / 当天 8:00）。
    if (task.remindOffsetMin == null) {
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

  /// 每日重复提醒：设了提醒时刻且可排未来首触发 → 按时每日重复通知；
  /// 未设 / 已完成 /（区间型）区间已结束 → 取消对应通知。
  Future<void> _scheduleDailyRepeat(Task task, int id,
      {bool? vibrate}) async {
    final String? hhmm = task.dailyRemindTime;
    final DateTime? firstAt = dailyRemindFirstAt(task, hhmm);
    if (firstAt == null) {
      await _service.plugin.cancel(id: id);
      return;
    }
    final bool vib = vibrate ??
        await _settings.getValue(NotificationSettingsKeys.taskVibrate) == 'true';
    await _schedule(
      id: id,
      title: task.title,
      body: _dailyBody(task, hhmm!),
      remindAt: firstAt,
      payload: NotificationPayload.taskReminder(task.id!),
      channelId:
          vib ? NotificationIds.vibrateChannelId : NotificationIds.defaultChannelId,
      matchDateTimeComponents: fln.DateTimeComponents.time,
    );
  }

  /// 每日提醒（每日重复）的首次触发时刻；不可调度返回 null。
  ///
  /// - daily / span（区间型）：从「今天」与「区间起点」较晚者起，取第一个晚于
  ///   [now] 的 `dailyRemindTime` 自然日（今天已过顺延次日；顺延超出截止日即
  ///   区间将尽 → null 停排）。区间非法 / 已过截止日 → null。
  /// - todo / scheduled：从今天起每天（今天已过顺延明天），无截止日；
  ///   「勾完成即停」由调度入口的 completed 分支处理，不进本函数。
  /// 时刻缺失 / 非法 → null。供调度分支与测试复用。
  static DateTime? dailyRemindFirstAt(Task task, String? hhmm,
      {DateTime? now}) {
    if (hhmm == null || !isValidTime24h(hhmm)) return null;
    final List<String> parts = hhmm.split(':');
    final int hour = int.parse(parts[0]);
    final int minute = int.parse(parts[1]);
    final DateTime current = now ?? DateTime.now();
    final DateTime today = _dateOnly(current);

    if (task.type == TaskType.daily || task.type == TaskType.span) {
      final DateTime start = _dateOnly(task.startDate ?? task.dueDate);
      final DateTime end = _dateOnly(task.dueDate);
      if (start.isAfter(end)) return null; // 非法区间（start > due）

      // 候选起始日：今天晚于区间起点从今天起排，否则等区间起点日。
      DateTime day = today.isAfter(start) ? today : start;
      if (day.isAfter(end)) return null; // 今天已超出区间，不再排。
      DateTime at = DateTime(day.year, day.month, day.day, hour, minute);
      if (!at.isAfter(current)) {
        final DateTime next = day.add(const Duration(days: 1));
        if (next.isAfter(end)) return null; // 今天时刻已过且无下一天可排。
        at = DateTime(next.year, next.month, next.day, hour, minute);
      }
      return at;
    }

    // todo / scheduled：今天该时刻未过 → 今天；已过 → 明天。无截止。
    DateTime at = DateTime(today.year, today.month, today.day, hour, minute);
    if (!at.isAfter(current)) {
      final DateTime next = today.add(const Duration(days: 1));
      at = DateTime(next.year, next.month, next.day, hour, minute);
    }
    return at;
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

  /// 发一条测试通知（供真机验证震动/渠道）。
  ///
  /// [vibrate] 为 null 时按「日程提醒震动」设置选渠道。内容标注走哪个渠道，
  /// 便于排查「弹了不震」属于渠道选择还是系统震动设置问题。
  /// [delay] 非零时先等待再弹出：国产 ROM 会抑制「正在使用 App」自己发的
  /// 通知（前台静默、无横幅无音无震），真实验证需先退到桌面/锁屏——故提供
  /// 延时让用户切后台后再触发。
  Future<void> sendVibrateTest({
    bool? vibrate,
    Duration delay = Duration.zero,
  }) async {
    await _service.initialize();
    final bool vib = vibrate ??
        await _settings.getValue(NotificationSettingsKeys.taskVibrate) ==
            'true';
    final String channelId = vib
        ? NotificationIds.vibrateChannelId
        : NotificationIds.defaultChannelId;
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    await _service.plugin.show(
      id: NotificationIds.testReminderId,
      title: 'Plai 测试提醒',
      body: vib ? '震动渠道 · 这条应伴随震动' : '普通渠道 · 这条不震动',
      notificationDetails: _notificationDetails(channelId),
    );
  }

  // ------------------------------------------------------------ 内部实现

  /// 按渠道构建通知详情（震动渠道：enableVibration + 显式节拍；普通渠道禁震）。
  fln.NotificationDetails _notificationDetails(String channelId) {
    final bool vib = channelId == NotificationIds.vibrateChannelId;
    return fln.NotificationDetails(
      android: fln.AndroidNotificationDetails(
        channelId,
        vib
            ? NotificationIds.vibrateChannelName
            : NotificationIds.defaultChannelName,
        channelDescription: vib
            ? NotificationIds.vibrateChannelDescription
            : NotificationIds.defaultChannelDescription,
        importance: fln.Importance.high,
        priority: fln.Priority.high,
        enableVibration: vib,
        // 震动渠道带显式节拍，防部分 ROM 忽略渠道默认震动。
        vibrationPattern: vib ? _vibrationPattern : null,
        // playSound 默认 true，sound 未指定 → 使用系统默认提示音。
      ),
      iOS: fln.DarwinNotificationDetails(),
    );
  }

  /// 统一调度入口：精确调度，失败时降级为非精确调度。
  ///
  /// [channelId]：按「提醒震动」开关选定的通知渠道；
  /// [matchDateTimeComponents]：非空时按组件重复（如每日打卡用
  /// `time` 每天同一时刻），为空则单次触发。
  Future<void> _schedule({
    required int id,
    required String title,
    required String body,
    required DateTime remindAt,
    required String payload,
    required String channelId,
    fln.DateTimeComponents? matchDateTimeComponents,
  }) async {
    final fln.NotificationDetails details = _notificationDetails(channelId);
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
        matchDateTimeComponents: matchDateTimeComponents,
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
        matchDateTimeComponents: matchDateTimeComponents,
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

  /// 每日重复提醒文案（系统每天按 [hhmm] 重发）。
  String _dailyBody(Task task, String hhmm) {
    final String prefix = switch (task.type) {
      TaskType.daily => '每日打卡',
      TaskType.span => '跨期任务',
      TaskType.scheduled => '定点日程',
      TaskType.todo => '待办任务',
    };
    return '$prefix · 每天 $hhmm';
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

  /// 归一到自然日（丢弃时刻）。
  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
}
