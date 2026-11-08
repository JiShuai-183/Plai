import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
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
import 'android_daily_reminder.dart';
import 'notification_ids.dart';
import 'notification_payload.dart';
import 'notification_service.dart';

/// 通知相关设置键（与设置模块共享，字面量不得随意改动）。
///
/// 设置模块读写这几个键即可联动提醒调度：
/// - [enabled]：通知总开关（'true' / 'false'），缺省视为开启；
/// - [classAdvanceMin]：上课提醒提前量（分钟，如 '10'）；
/// - [completeSound]：日程完成提示音的本地音频路径（空 = 不播放）；
/// - [keepAliveGuideShown]：国内 ROM 保活引导页是否已展示过（'true' / 'false'）。
///
/// 注：旧版还有「课程提醒震动 / 日程提醒震动」两个键（`notify.class_vibrate`
/// / `notify.task_vibrate`），随渠道改按内容划分一并移除 —— 震动改为在系统
/// 设置里按渠道控制，见 [NotificationIds] 的渠道说明。
abstract final class NotificationSettingsKeys {
  /// 通知总开关设置键。
  static const String enabled = 'notify.enabled';

  /// 上课提醒提前量（分钟）设置键。
  static const String classAdvanceMin = 'notify.class_advance_min';

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
    DateTime Function()? now,
  }) : _service = service ?? NotificationService.instance,
       _now = now ?? DateTime.now;

  final ITimetableRepository _timetable;
  final ITaskRepository _tasks;
  final ISettingsRepository _settings;
  final NotificationService _service;
  final DateTime Function() _now;
  final Map<int, Future<void>> _dailyScheduling = {};

  // ------------------------------------------------------------ 上课提醒

  /// 调度一次上课提醒（单次）。
  ///
  /// - [course]：课程；
  /// - [date]：上课日期（仅年月日，具体到天）；
  /// - [time]：上课时刻（节次开始时间）；
  /// - [advanceMin]：提前提醒分钟数（≥0，来自设置的提前量）；
  /// - [week]：第几周（通知 ID 稳定 + 点击通知定位课表周）。
  ///
  /// 固定走**课表渠道** [NotificationIds.classChannelId]。
  ///
  /// 触发时刻 = date + time - advanceMin；已过期则自动跳过（不调度）。
  /// 同一课程同一周重复调用会覆盖旧通知（同 ID）。
  Future<void> scheduleClassReminder({
    required Course course,
    required DateTime date,
    required TimeOfDay time,
    required int advanceMin,
    required int week,
  }) async {
    await _service.initialize();
    final int? courseId = course.id;
    if (courseId == null) return; // 未入库课程（无主键）无法调度

    final DateTime remindAt = _combine(
      date,
      time,
    ).subtract(Duration(minutes: advanceMin));
    if (!remindAt.isAfter(DateTime.now())) return; // 已过期

    await _schedule(
      id: NotificationIds.classReminderId(courseId, week),
      title: '${course.name} · 上课提醒',
      body: _classBody(course, date, time, week, advanceMin),
      remindAt: remindAt,
      payload: NotificationPayload.classReminder(courseId, week),
      channelId: NotificationIds.classChannelId,
    );
  }

  // ------------------------------------------------------------ 任务提醒

  /// 调度任务的提醒；存量单次 offset 提醒（旧版 UI）仍兼容调度。
  ///
  /// **「不重复」提醒**：[Task.reminderRepeat] == once → 只在 [Task.remindOnceAt]
  /// 那一刻响一次（见 [onceRemindAt]），不挂每日重复组件；过期 / 缺失即取消。
  ///
  /// **每日重复提醒（所有类型统一）**：设了 [Task.dailyRemindTime] → 每天同一
  /// 时刻一条重复通知（首次触发见 [dailyRemindFirstAt]，之后系统按时每日重发）；
  /// 未设 / 已完成 / 区间已结束 → 取消该任务通知。
  /// - daily：读打卡日志跳过已完成候选日，Android 保留明确起始日继续重复；
  ///   无期限时长期重复；iOS 延后无限重复的限制见提醒调度接口文档；
  /// - span：起止区间内每天重复；
  /// - todo / scheduled：从今天起每天重复，直到勾完成（completed 分支取消）。
  /// 注：重复通知系统不会在截止日自动停发，靠下次本任务/全量重排顺带清理。
  ///
  /// **存量单次提醒兼容**：旧版 scheduled / todo 曾配过 remindOffsetMin /
  /// remindDate，若未设每日提醒，仍按单次触发（触发时刻见 [_taskRemindAt]），
  /// 老数据不丢提醒。
  ///
  /// 固定走**日程渠道** [NotificationIds.taskChannelId]。
  Future<void> scheduleTaskReminder(Task task) async {
    final taskId = task.id;
    if (task.type != TaskType.daily || taskId == null) {
      return _scheduleTaskReminder(task);
    }
    final previous = _dailyScheduling[taskId];
    final current = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // 前一调用仍向其调用方抛错；单项失败不能阻断下一次重新读取日志。
        }
      }
      await _scheduleTaskReminder(task);
    }();
    _dailyScheduling[taskId] = current;
    try {
      await current;
    } finally {
      if (identical(_dailyScheduling[taskId], current)) {
        _dailyScheduling.remove(taskId);
      }
    }
  }

  Future<void> _scheduleTaskReminder(Task task) async {
    await _service.initialize();
    final int? taskId = task.id;
    if (taskId == null) return;

    final int id = NotificationIds.taskReminderId(taskId);
    if (task.completed) {
      await _service.plugin.cancel(id: id);
      return;
    }
    // 「不重复」优先：显式字段，老数据为 null 才走后面的每日 / 存量分支。
    if (task.reminderRepeat == ReminderRepeat.once) {
      await _scheduleOnce(task, id);
      return;
    }
    if (task.dailyRemindTime != null) {
      await _scheduleDailyRepeat(task, id);
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

    await _schedule(
      id: id,
      title: task.title,
      body: _taskBody(task),
      remindAt: remindAt,
      payload: NotificationPayload.taskReminder(taskId),
      channelId: NotificationIds.taskChannelId,
    );
  }

  /// 每日重复提醒：设了提醒时刻且可排未来首触发 → 按时每日重复通知；
  /// 未设 / 已完成 /（区间型）区间已结束 → 取消对应通知。
  ///
  /// 固定走**日程渠道** [NotificationIds.taskChannelId]。
  Future<void> _scheduleDailyRepeat(Task task, int id) async {
    if (task.type == TaskType.daily) {
      await _scheduleDailyCheckIn(task, id);
      return;
    }
    final String? hhmm = task.dailyRemindTime;
    final DateTime? firstAt = dailyRemindFirstAt(task, hhmm);
    if (firstAt == null) {
      await _service.plugin.cancel(id: id);
      return;
    }
    await _schedule(
      id: id,
      title: task.title,
      body: _dailyBody(task, hhmm!),
      remindAt: firstAt,
      payload: NotificationPayload.taskReminder(task.id!),
      channelId: NotificationIds.taskChannelId,
      matchDateTimeComponents: fln.DateTimeComponents.time,
    );
  }

  /// 打卡按自然日完成，不能用 task.completed 代替日志。先取消旧 alarm/已显示
  /// 通知再读日志；任何失败向上传递，绝不以「未完成」兜底重新排今天。
  Future<void> _scheduleDailyCheckIn(Task task, int id) async {
    await _service.plugin.cancel(id: id);
    if (await _settings.getValue(NotificationSettingsKeys.enabled) == 'false') {
      return;
    }
    final now = _now();
    var firstAt = dailyRemindFirstAt(task, task.dailyRemindTime, now: now);
    if (firstAt == null) return;
    final completedDays = (await _tasks.dailyLogsFor(task.id!))
        .map(_dateOnly)
        .toSet();
    while (completedDays.contains(_dateOnly(firstAt!))) {
      firstAt = DateTime(
        firstAt.year,
        firstAt.month,
        firstAt.day + 1,
        firstAt.hour,
        firstAt.minute,
      );
      if (task.dueDate != null &&
          _dateOnly(firstAt).isAfter(_dateOnly(task.dueDate!))) {
        return;
      }
    }
    if (defaultTargetPlatform != TargetPlatform.android) {
      // iOS 的无限 time 重复只保留 HH:mm，无法延后首次触发到指定日期。
      // 需要跳过自然下一次时显式失败；保留取消结果，避免今天错误提醒。
      final naturalNext = DateTime(
        now.year,
        now.month,
        now.day,
        firstAt.hour,
        firstAt.minute,
      );
      final naturalDay = naturalNext.isAfter(now)
          ? _dateOnly(now)
          : DateTime(now.year, now.month, now.day + 1);
      if (_dateOnly(firstAt).isAfter(naturalDay)) {
        throw UnsupportedError('当前平台不支持跳过已打卡日期后恢复无限重复提醒');
      }
      await _schedule(
        id: id,
        title: task.title,
        body: _dailyBody(task, task.dailyRemindTime!),
        remindAt: firstAt,
        payload: NotificationPayload.taskReminder(task.id!),
        channelId: NotificationIds.taskChannelId,
        matchDateTimeComponents: fln.DateTimeComponents.time,
      );
      return;
    }
    Future<void> schedule(fln.AndroidScheduleMode mode) =>
        AndroidDailyReminder.schedule(
          id: id,
          title: task.title,
          body: _dailyBody(task, task.dailyRemindTime!),
          firstAt: tz.TZDateTime.from(firstAt!, tz.local),
          payload: NotificationPayload.taskReminder(task.id!),
          details: _notificationDetails(NotificationIds.taskChannelId).android!,
          mode: mode,
        );
    try {
      await schedule(fln.AndroidScheduleMode.exactAllowWhileIdle);
    } on PlatformException {
      await schedule(fln.AndroidScheduleMode.inexactAllowWhileIdle);
    }
  }

  /// 「不重复」提醒：单次触发（不挂每日重复组件，因此不会每天重发）。
  /// 触发时刻见 [onceRemindAt]；缺失 / 已过期 → 取消该任务通知。
  ///
  /// 固定走**日程渠道** [NotificationIds.taskChannelId]。
  Future<void> _scheduleOnce(Task task, int id) async {
    final isDaily = task.type == TaskType.daily;
    if (isDaily) {
      await _service.plugin.cancel(id: id);
      if (await _settings.getValue(NotificationSettingsKeys.enabled) ==
          'false') {
        return;
      }
    }
    final DateTime? at = onceRemindAt(task, now: isDaily ? _now() : null);
    if (at == null) {
      if (!isDaily) await _service.plugin.cancel(id: id);
      return;
    }
    if (isDaily && await _tasks.isDailyCompleted(task.id!, _dateOnly(at))) {
      return; // 显式一次提醒只针对该自然日；完成后取消，不顺延。
    }
    await _schedule(
      id: id,
      title: task.title,
      body: _onceBody(task, at),
      remindAt: at,
      payload: NotificationPayload.taskReminder(task.id!),
      channelId: NotificationIds.taskChannelId,
    );
  }

  /// 「不重复」提醒的触发时刻；不可调度返回 null。
  ///
  /// - 只在 [Task.remindOnceAt] 那一刻响一次，秒/毫秒归零（与滚轮选择粒度一致）；
  /// - 缺失 / 已过期（不晚于 [now]）→ null，避免恢复旧备份后立刻误响；
  /// - 与任务截止日无关（「不重复」可提前任意天提醒），故不校验区间。
  static DateTime? onceRemindAt(Task task, {DateTime? now}) {
    final DateTime? at = task.remindOnceAt;
    if (at == null) return null;
    final DateTime normalized = DateTime(
      at.year,
      at.month,
      at.day,
      at.hour,
      at.minute,
    );
    final DateTime current = now ?? DateTime.now();
    if (!normalized.isAfter(current)) return null;
    return normalized;
  }

  /// 每日提醒（每日重复）的首次触发时刻；不可调度返回 null。
  ///
  /// - daily / span（区间型）：从「今天」与「区间起点」较晚者起，取第一个晚于
  ///   [now] 的 `dailyRemindTime` 自然日（今天已过顺延次日；顺延超出截止日即
  ///   区间将尽 → null 停排）。区间非法 / 已过截止日 → null。
  ///   daily 无截止时从今天（或已指定的未来起点）开始，长期重复；span 必须有截止。
  /// - todo / scheduled：从今天起每天（今天已过顺延明天），无截止日；
  ///   「勾完成即停」由调度入口的 completed 分支处理，不进本函数。
  /// 时刻缺失 / 非法 → null。供调度分支与测试复用。
  static DateTime? dailyRemindFirstAt(
    Task task,
    String? hhmm, {
    DateTime? now,
  }) {
    if (hhmm == null || !isValidTime24h(hhmm)) return null;
    final List<String> parts = hhmm.split(':');
    final int hour = int.parse(parts[0]);
    final int minute = int.parse(parts[1]);
    final DateTime current = now ?? DateTime.now();
    final DateTime today = _dateOnly(current);

    if (task.type == TaskType.daily || task.type == TaskType.span) {
      final DateTime? dueDate = task.dueDate;
      if (task.type == TaskType.span && dueDate == null) return null;
      final DateTime start = _dateOnly(task.startDate ?? dueDate ?? today);
      final DateTime? end = dueDate == null ? null : _dateOnly(dueDate);
      if (end != null && start.isAfter(end)) return null; // 非法区间

      // 候选起始日：今天晚于区间起点从今天起排，否则等区间起点日。
      DateTime day = today.isAfter(start) ? today : start;
      if (end != null && day.isAfter(end)) return null; // 今天已超出区间，不再排。
      DateTime at = DateTime(day.year, day.month, day.day, hour, minute);
      if (!at.isAfter(current)) {
        final DateTime next = day.add(const Duration(days: 1));
        if (end != null && next.isAfter(end)) return null;
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
    final List<fln.PendingNotificationRequest> pending = await _service.plugin
        .pendingNotificationRequests();
    for (final fln.PendingNotificationRequest req in pending) {
      final NotificationIntent? intent = NotificationPayload.parse(req.payload);
      if (intent == null) continue;
      final bool matchCourse =
          courseId != null &&
          intent.type == NotificationIntentType.classReminder &&
          intent.courseId == courseId;
      final bool matchTask =
          taskId != null &&
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
        int.tryParse(
          allSettings[NotificationSettingsKeys.classAdvanceMin] ?? '',
        ) ??
        NotificationSettingsKeys.defaultClassAdvanceMin;

    // 任务
    final List<Task> tasks = await _tasks.getTasks(completed: false);
    for (final Task task in tasks) {
      await scheduleTaskReminder(task);
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
        );
      }
    }
  }

  // ------------------------------------------------------------ 保活引导

  /// 是否需要展示国内 ROM 保活引导页（首次开启提醒时）。
  Future<bool> shouldShowKeepAliveGuide() async {
    final String? value = await _settings.getValue(
      NotificationSettingsKeys.keepAliveGuideShown,
    );
    return value != 'true';
  }

  /// 标记保活引导页已展示。
  Future<void> markKeepAliveGuideShown() =>
      _settings.setValue(NotificationSettingsKeys.keepAliveGuideShown, 'true');

  // ------------------------------------------------------------ 内部实现

  /// 按渠道构建通知详情。
  ///
  /// 渠道名 / 描述按 [channelId] 由 [NotificationIds.channelMetaOf] 解析；
  /// 震动是渠道级属性，这里不再单独设置（系统设置按渠道控制）。
  fln.NotificationDetails _notificationDetails(String channelId) {
    final ({String name, String description}) meta =
        NotificationIds.channelMetaOf(channelId);
    return fln.NotificationDetails(
      android: fln.AndroidNotificationDetails(
        channelId,
        meta.name,
        channelDescription: meta.description,
        importance: fln.Importance.high,
        priority: fln.Priority.high,
        // 通知音跟随系统默认：playSound 为 true 但不指定 sound，插件在
        // Android 8+ 走渠道默认音、pre-O 设备回落到
        // RingtoneManager 默认通知音，两端都随系统设置。
        // 代价：系统默认通知音被设为「无 / 静默」时通知没声音，属预期。
        playSound: true,
      ),
      iOS: fln.DarwinNotificationDetails(),
    );
  }

  /// 统一调度入口：精确调度，失败时降级为非精确调度。
  ///
  /// [channelId]：按提醒类型选定的通知渠道（课表 / 日程）；
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
    // 无截止不能沿用旧offset或冗余remindDate；只接受上面的独立显式提醒。
    if (task.dueDate == null) return null;
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
  static DateTime? _combineDueTime(DateTime? date, String? time) {
    if (date == null) return null;
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
    Course course,
    DateTime date,
    TimeOfDay time,
    int week,
    int advanceMin,
  ) {
    final String dateStr = dateOnlyToString(date);
    final String timeStr = '${_two(time.hour)}:${_two(time.minute)}';
    final String loc = course.location.isEmpty ? '' : ' · ${course.location}';
    final String advance = advanceMin > 0 ? '（提前 $advanceMin 分钟）' : '';
    return '第 $week 周 ${_weekdayLabel(course.weekday)} $timeStr$loc$advance ｜ $dateStr';
  }

  /// 每日重复提醒文案（系统每天按 [hhmm] 重发）。
  String _dailyBody(Task task, String hhmm) {
    return '${_typePrefix(task.type)} · 每天 $hhmm';
  }

  /// 「不重复」提醒文案（只在 [at] 那一刻响一次）。
  String _onceBody(Task task, DateTime at) {
    return '${_typePrefix(task.type)} · ${at.month}月${at.day}日 '
        '${_two(at.hour)}:${_two(at.minute)}';
  }

  /// 提醒文案的任务类型前缀。
  static String _typePrefix(TaskType type) {
    return switch (type) {
      TaskType.daily => '每日打卡',
      TaskType.span => '跨期任务',
      TaskType.scheduled => '定时日程',
      TaskType.todo => '待办任务',
    };
  }

  /// 任务提醒文案。
  String _taskBody(Task task) {
    final DateTime? dueDate = task.dueDate;
    final String dateStr = dueDate == null ? '无截止' : dateOnlyToString(dueDate);
    final String timeStr = task.dueTime ?? '';
    final String at = timeStr.isEmpty ? '' : ' $timeStr';
    final String prefix = task.type == TaskType.scheduled ? '定时日程' : '待办任务';
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
