import 'package:flutter_test/flutter_test.dart';
import 'package:plai/services/notifications/notification_ids.dart';

void main() {
  group('NotificationIds', () {
    test('上课提醒 ID：同一课程同一周稳定，不同周不同', () {
      expect(NotificationIds.classReminderId(1, 1),
          NotificationIds.classReminderId(1, 1));
      expect(NotificationIds.classReminderId(1, 1),
          isNot(NotificationIds.classReminderId(1, 2)));
      expect(NotificationIds.classReminderId(1, 1),
          isNot(NotificationIds.classReminderId(2, 1)));
    });

    test('任务提醒 ID 与上课提醒 ID 分区分隔，互不冲突', () {
      expect(NotificationIds.taskReminderId(1),
          isNot(NotificationIds.classReminderId(1, 1)));
      expect(NotificationIds.taskReminderId(1),
          isNot(NotificationIds.taskReminderId(2)));
    });

    test('ID 落在 32 位有符号 int 范围内', () {
      for (int courseId = 1; courseId <= 10000; courseId++) {
        for (int week = 1; week <= 99; week++) {
          final id = NotificationIds.classReminderId(courseId, week);
          expect(id, greaterThan(0));
          expect(id, lessThanOrEqualTo(0x7FFFFFFF));
        }
      }
      expect(NotificationIds.taskReminderId(1000000),
          lessThanOrEqualTo(0x7FFFFFFF));
    });
  });
}
