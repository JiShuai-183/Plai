import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    as fln;
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/services/notifications/notification_diagnostics.dart';
import 'package:plai/services/notifications/notification_payload.dart';

/// 构造待触发通知（插件构造函数为位置参数 id/title/body/payload）。
fln.PendingNotificationRequest req(int id, String? payload) =>
    fln.PendingNotificationRequest(id, null, null, payload);

NotificationDiagnostics diagnostics({
  bool? notificationsEnabled = true,
  bool? exactAlarmsAllowed = true,
  bool remindersEnabled = true,
  int pendingClassCount = 0,
  int pendingTaskCount = 0,
  int pendingOtherCount = 0,
  DateTime? lastRescheduleAt,
  String? lastRescheduleResult,
  int? lastRescheduleCount,
  int degradedScheduleCount = 0,
  String osVersion = 'Android 13',
}) =>
    NotificationDiagnostics(
      notificationsEnabled: notificationsEnabled,
      exactAlarmsAllowed: exactAlarmsAllowed,
      remindersEnabled: remindersEnabled,
      pendingClassCount: pendingClassCount,
      pendingTaskCount: pendingTaskCount,
      pendingOtherCount: pendingOtherCount,
      lastRescheduleAt: lastRescheduleAt,
      lastRescheduleResult: lastRescheduleResult,
      lastRescheduleCount: lastRescheduleCount,
      degradedScheduleCount: degradedScheduleCount,
      osVersion: osVersion,
    );

void main() {
  group('summarizePending', () {
    test('空列表 → 三类均为 0', () {
      final s = summarizePending(const <fln.PendingNotificationRequest>[]);
      expect(s.classCount, 0);
      expect(s.taskCount, 0);
      expect(s.otherCount, 0);
      expect(s.total, 0);
    });

    test('按 payload 归类：上课 / 日程 / 其他', () {
      final s = summarizePending(<fln.PendingNotificationRequest>[
        req(1, NotificationPayload.classReminder(1, 1)),
        req(2, NotificationPayload.classReminder(2, 3)),
        req(3, NotificationPayload.taskReminder(5)),
        req(4, NotificationPayload.taskReminder(6)),
        req(5, NotificationPayload.taskReminder(7)),
      ]);
      expect(s.classCount, 2);
      expect(s.taskCount, 3);
      expect(s.otherCount, 0);
      expect(s.total, 5);
    });

    test('无法解析的 payload 归入「其他」', () {
      final s = summarizePending(<fln.PendingNotificationRequest>[
        req(1, NotificationPayload.classReminder(1, 1)),
        req(2, ''), // 测试提醒的空串 payload
        req(3, null),
        req(4, '不是 JSON'),
        req(5, '{"type":"unknown"}'),
        req(6, '{"type":"class"}'), // 缺字段 → 解析失败
      ]);
      expect(s.classCount, 1);
      expect(s.taskCount, 0);
      expect(s.otherCount, 5);
      expect(s.total, 6);
    });
  });

  group('diagnosticsToPlainText', () {
    test('包含关键字段且可读', () {
      final text = diagnosticsToPlainText(diagnostics(
        notificationsEnabled: false,
        exactAlarmsAllowed: null,
        remindersEnabled: true,
        pendingClassCount: 3,
        pendingTaskCount: 2,
        lastRescheduleAt: DateTime(2026, 9, 12, 10, 0),
        lastRescheduleResult: 'ok',
        lastRescheduleCount: 5,
        degradedScheduleCount: 1,
        osVersion: 'Android 13 (API 33)',
      ));
      expect(text, contains('系统版本: Android 13 (API 33)'));
      expect(text, contains('通知权限: 异常'));
      expect(text, contains('精确闹钟: 未知'));
      expect(text, contains('App 内总开关: 开启'));
      expect(text, contains('上课 3 条'));
      expect(text, contains('日程 2 条'));
      expect(text, contains('合计 5 条'));
      expect(text, contains('本次启动降级条数: 1'));
    });

    test('未知字段降级为「未知」而不抛', () {
      final text = diagnosticsToPlainText(diagnostics(
        notificationsEnabled: null,
        exactAlarmsAllowed: null,
        remindersEnabled: false,
        lastRescheduleAt: null,
        osVersion: '未知',
      ));
      expect(text, contains('通知权限: 未知'));
      expect(text, contains('App 内总开关: 关闭'));
      expect(text, contains('上次重排: 未知'));
    });
  });
}
