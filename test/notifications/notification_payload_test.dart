import 'package:flutter_test/flutter_test.dart';
import 'package:plai/services/notifications/notification_payload.dart';

void main() {
  group('NotificationPayload 编解码', () {
    test('上课提醒 payload 往返解析', () {
      final payload = NotificationPayload.classReminder(12, 5);
      final intent = NotificationPayload.parse(payload);
      expect(intent, isNotNull);
      expect(intent!.type, NotificationIntentType.classReminder);
      expect(intent.courseId, 12);
      expect(intent.week, 5);
      expect(intent.taskId, isNull);
    });

    test('任务提醒 payload 往返解析', () {
      final payload = NotificationPayload.taskReminder(3);
      final intent = NotificationPayload.parse(payload);
      expect(intent, isNotNull);
      expect(intent!.type, NotificationIntentType.taskReminder);
      expect(intent.taskId, 3);
      expect(intent.courseId, isNull);
      expect(intent.week, isNull);
    });

    test('非法 / 空 payload 返回 null', () {
      expect(NotificationPayload.parse(null), isNull);
      expect(NotificationPayload.parse(''), isNull);
      expect(NotificationPayload.parse('不是 JSON'), isNull);
      expect(NotificationPayload.parse('{"type":"unknown"}'), isNull);
      expect(NotificationPayload.parse('{"type":"class"}'), isNull);
    });

    test('同一课程不同周 / 不同课程 payload 可区分', () {
      final a = NotificationPayload.parse(NotificationPayload.classReminder(1, 1));
      final b = NotificationPayload.parse(NotificationPayload.classReminder(1, 2));
      final c = NotificationPayload.parse(NotificationPayload.classReminder(2, 1));
      expect(a!.week, 1);
      expect(b!.week, 2);
      expect(c!.courseId, 2);
    });
  });
}
