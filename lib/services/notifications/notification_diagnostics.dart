import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    as fln;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/app_database.dart';
import '../../data/repositories/settings_repository.dart';
import 'notification_payload.dart';
import 'notification_scheduler.dart';
import 'notification_service.dart';

/// 待触发通知的分类统计（按 payload 归类）。
///
/// - [classCount]：上课提醒（payload `type=class`）；
/// - [taskCount]：日程 / 待办提醒（payload `type=task`）；
/// - [otherCount]：无法解析 / 其它 payload（含测试提醒的空串）。
class PendingSummary {
  const PendingSummary({
    required this.classCount,
    required this.taskCount,
    required this.otherCount,
  });

  final int classCount;
  final int taskCount;
  final int otherCount;

  /// 合计条数。
  int get total => classCount + taskCount + otherCount;
}

/// 把「系统里待触发的通知」按 payload 分类计数。
///
/// 纯函数，与 IO 解耦以便单测；解析失败 / 空 payload 一律归入 [PendingSummary.otherCount]。
PendingSummary summarizePending(
  List<fln.PendingNotificationRequest> pending,
) {
  int classCount = 0;
  int taskCount = 0;
  int otherCount = 0;
  for (final fln.PendingNotificationRequest req in pending) {
    final NotificationIntent? intent = NotificationPayload.parse(req.payload);
    switch (intent?.type) {
      case NotificationIntentType.classReminder:
        classCount++;
      case NotificationIntentType.taskReminder:
        taskCount++;
      case null:
        otherCount++;
    }
  }
  return PendingSummary(
    classCount: classCount,
    taskCount: taskCount,
    otherCount: otherCount,
  );
}

/// 提醒诊断快照：自检页展示所需的全部只读信息。
///
/// 字段可空处代表「无法判定 / 读取失败降级为未知」，页面须能容忍 null，
/// 诊断采集本身绝不抛异常（否则自检页白屏，失去排查价值）。
class NotificationDiagnostics {
  const NotificationDiagnostics({
    required this.notificationsEnabled,
    required this.exactAlarmsAllowed,
    required this.remindersEnabled,
    required this.pendingClassCount,
    required this.pendingTaskCount,
    required this.pendingOtherCount,
    required this.lastRescheduleAt,
    required this.lastRescheduleResult,
    required this.lastRescheduleCount,
    required this.degradedScheduleCount,
    required this.osVersion,
  });

  /// 通知权限是否已授予；null = 无法判定。
  final bool? notificationsEnabled;

  /// 是否允许精确闹钟（`SCHEDULE_EXACT_ALARM`）；null = 无法判定。
  final bool? exactAlarmsAllowed;

  /// App 内「通知总开关」是否开启（缺省视为开启）。
  final bool remindersEnabled;

  /// 系统里实际待触发的上课提醒条数。
  final int pendingClassCount;

  /// 系统里实际待触发的日程 / 待办提醒条数。
  final int pendingTaskCount;

  /// 系统里其它待触发通知条数（无法归类）。
  final int pendingOtherCount;

  /// 上次全量重排完成时间；null = 本次安装以来未重排过或读取失败。
  final DateTime? lastRescheduleAt;

  /// 上次全量重排结果：`ok` / `disabled` / `failed`；null = 未知。
  final String? lastRescheduleResult;

  /// 上次全量重排排下的条数；null = 未知。
  final int? lastRescheduleCount;

  /// 本次进程内精确调度降级为非精确调度的累计次数。
  final int degradedScheduleCount;

  /// 系统版本串（[Platform.operatingSystemVersion]）。
  final String osVersion;

  /// 系统里待触发通知的总条数。
  int get pendingTotal =>
      pendingClassCount + pendingTaskCount + pendingOtherCount;
}

/// 采集一次提醒诊断快照。
///
/// 每一步失败都降级为「未知 / null / 0」，绝不抛异常 —— 诊断页自身不能白屏。
Future<NotificationDiagnostics> collectNotificationDiagnostics() async {
  final NotificationService service = NotificationService.instance;
  final ISettingsRepository settings = SettingsRepository(AppDatabase.instance);

  bool? notificationsEnabled;
  try {
    notificationsEnabled = await service.areNotificationsEnabled();
  } catch (_) {
    // 降级为未知。
  }

  bool? exactAlarmsAllowed;
  try {
    exactAlarmsAllowed = await service.canScheduleExactAlarms();
  } catch (_) {
    // 降级为未知。
  }

  bool remindersEnabled = true;
  DateTime? lastAt;
  String? lastResult;
  int? lastCount;
  try {
    final Map<String, String> all = await settings.getAll();
    remindersEnabled = all[NotificationSettingsKeys.enabled] != 'false';
    final String? at = all[NotificationSettingsKeys.lastRescheduleAt];
    if (at != null) lastAt = DateTime.tryParse(at);
    lastResult = all[NotificationSettingsKeys.lastRescheduleResult];
    final String? count = all[NotificationSettingsKeys.lastRescheduleCount];
    if (count != null) lastCount = int.tryParse(count);
  } catch (_) {
    // 降级为默认 / 未知。
  }

  PendingSummary summary = const PendingSummary(
    classCount: 0,
    taskCount: 0,
    otherCount: 0,
  );
  try {
    summary = summarizePending(
      await service.plugin.pendingNotificationRequests(),
    );
  } catch (_) {
    // 插件不可用（如测试宿主 / 未初始化）→ 按 0 处理。
  }

  String osVersion;
  try {
    osVersion = Platform.operatingSystemVersion;
  } catch (_) {
    osVersion = '未知';
  }

  return NotificationDiagnostics(
    notificationsEnabled: notificationsEnabled,
    exactAlarmsAllowed: exactAlarmsAllowed,
    remindersEnabled: remindersEnabled,
    pendingClassCount: summary.classCount,
    pendingTaskCount: summary.taskCount,
    pendingOtherCount: summary.otherCount,
    lastRescheduleAt: lastAt,
    lastRescheduleResult: lastResult,
    lastRescheduleCount: lastCount,
    degradedScheduleCount: NotificationScheduler.degradedScheduleCount,
    osVersion: osVersion,
  );
}

/// 把诊断快照拼成纯文本（供「复制诊断信息」按钮写入剪贴板）。
///
/// 纯函数，便于测试；不依赖 UI。
String diagnosticsToPlainText(NotificationDiagnostics d) {
  String yesNo(bool? v) => v == null ? '未知' : (v ? '正常' : '异常');
  final StringBuffer b = StringBuffer();
  b.writeln('Plai 提醒诊断');
  b.writeln('系统版本: ${d.osVersion}');
  b.writeln('通知权限: ${yesNo(d.notificationsEnabled)}');
  b.writeln('精确闹钟: ${yesNo(d.exactAlarmsAllowed)}');
  b.writeln('App 内总开关: ${d.remindersEnabled ? '开启' : '关闭'}');
  b.writeln(
    '系统里待触发提醒: 上课 ${d.pendingClassCount} 条 · '
    '日程 ${d.pendingTaskCount} 条 · 其他 ${d.pendingOtherCount} 条 '
    '（合计 ${d.pendingTotal} 条）',
  );
  b.writeln(
    '上次重排: ${d.lastRescheduleAt?.toIso8601String() ?? '未知'} · '
    '${d.lastRescheduleResult ?? '未知'} · '
    '${d.lastRescheduleCount?.toString() ?? '未知'} 条',
  );
  b.writeln('本次启动降级条数: ${d.degradedScheduleCount}');
  return b.toString();
}

/// 提醒诊断数据 Provider。
///
/// 自检页 watch 它；测试可 `overrideWith` 注入假数据（无需真机 / 插件）。
final notificationDiagnosticsProvider =
    FutureProvider<NotificationDiagnostics>((ref) async {
  return collectNotificationDiagnostics();
});
