import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/services/notifications/notification_ids.dart';
import 'package:plai/services/notifications/notification_service.dart';

/// 构造期望渠道（跟随系统默认音：不指定 sound）。
AndroidNotificationChannel _target({
  bool playSound = true,
  bool enableVibration = false,
  Importance importance = Importance.high,
  String? description = 'desc',
  AndroidNotificationSound? sound,
}) {
  return AndroidNotificationChannel(
    'plai_class_reminders',
    '课表提醒',
    description: description,
    importance: importance,
    playSound: playSound,
    enableVibration: enableVibration,
    sound: sound,
  );
}

/// 构造已有渠道，默认各属性与 [_target] 一致（声音为系统默认 URI）。
AndroidNotificationChannel _current({
  String? sound = 'content://settings/system/notification_sound',
  bool? playSound,
  bool? enableVibration,
  Importance? importance,
  String? description = 'desc',
}) {
  return AndroidNotificationChannel(
    'plai_class_reminders',
    '课表提醒',
    description: description,
    importance: importance ?? Importance.high,
    playSound: playSound ?? true,
    enableVibration: enableVibration ?? false,
    sound: sound == null ? null : UriAndroidNotificationSound(sound),
  );
}

void main() {
  group('desiredChannels（按内容划分）', () {
    test('恰为两条：课表提醒 + 日程提醒', () {
      expect(NotificationService.desiredChannels, hasLength(2));
      final List<AndroidNotificationChannel> channels =
          NotificationService.desiredChannels;
      expect(channels[0].id, NotificationIds.classChannelId);
      expect(channels[0].id, 'plai_class_reminders');
      expect(channels[0].name, '课表提醒');
      expect(channels[1].id, NotificationIds.taskChannelId);
      expect(channels[1].id, 'plai_task_reminders');
      expect(channels[1].name, '日程提醒');
    });

    test('两条渠道属性一致：high / 有声（跟随系统默认）/ 不震动', () {
      for (final AndroidNotificationChannel ch
          in NotificationService.desiredChannels) {
        expect(ch.importance, Importance.high);
        expect(ch.playSound, isTrue);
        expect(ch.enableVibration, isFalse);
        expect(ch.sound, isNull); // 不指定 sound = 跟随系统默认音
      }
    });
  });

  group('NotificationIds.channelMetaOf', () {
    test('课表渠道 → 课表提醒名称 / 描述', () {
      final ({String name, String description}) meta =
          NotificationIds.channelMetaOf(NotificationIds.classChannelId);
      expect(meta.name, NotificationIds.classChannelName);
      expect(meta.description, NotificationIds.classChannelDescription);
    });

    test('日程渠道 → 日程提醒名称 / 描述', () {
      final ({String name, String description}) meta =
          NotificationIds.channelMetaOf(NotificationIds.taskChannelId);
      expect(meta.name, NotificationIds.taskChannelName);
      expect(meta.description, NotificationIds.taskChannelDescription);
    });
  });

  group('shouldRecreateChannel', () {
    test('渠道不存在 → 重建', () {
      expect(shouldRecreateChannel(null, _target()), isTrue);
    });

    test('重要性不符 → 重建', () {
      expect(
        shouldRecreateChannel(
            _current(importance: Importance.defaultImportance), _target()),
        isTrue,
      );
    });

    test('playSound 不符 → 重建', () {
      expect(
        shouldRecreateChannel(_current(playSound: false), _target()),
        isTrue,
      );
    });

    test('enableVibration 不符 → 重建', () {
      expect(
        shouldRecreateChannel(_current(enableVibration: true), _target()),
        isTrue,
      );
    });

    test('描述不同但其余一致 → 不重建（刻意不比描述，防每次启动重建）', () {
      expect(
        shouldRecreateChannel(_current(description: '旧描述'), _target()),
        isFalse,
      );
      // 回读描述为 null（部分 ROM 可能如此）也不应触发重建。
      expect(
        shouldRecreateChannel(_current(description: null), _target()),
        isFalse,
      );
    });

    test('声音是系统默认 URI、其余属性一致 → 不重建（回归防线）', () {
      expect(shouldRecreateChannel(_current(), _target()), isFalse);
    });

    test('声音是用户自选音、其余属性一致 → 不重建', () {
      expect(
        shouldRecreateChannel(
          _current(sound: 'content://media/internal/audio/media/42'),
          _target(),
        ),
        isFalse,
      );
    });

    test('声音为空、其余属性一致 → 不重建', () {
      expect(shouldRecreateChannel(_current(sound: null), _target()), isFalse);
    });

    test('目标显式指定声音时才比对：不符 → 重建', () {
      final AndroidNotificationChannel target = _target(
        sound: const RawResourceAndroidNotificationSound('other'),
      );
      expect(shouldRecreateChannel(_current(sound: null), target), isTrue);
    });

    test('目标显式指定声音且与已有渠道一致 → 不重建', () {
      final AndroidNotificationChannel target = _target(
        sound: const UriAndroidNotificationSound('content://custom/1'),
      );
      expect(
        shouldRecreateChannel(_current(sound: 'content://custom/1'), target),
        isFalse,
      );
    });
  });
}
