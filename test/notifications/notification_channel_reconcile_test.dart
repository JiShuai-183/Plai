import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
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
    'plai_reminders',
    '上课与任务提醒',
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
    'plai_reminders',
    '上课与任务提醒',
    description: description,
    importance: importance ?? Importance.high,
    playSound: playSound ?? true,
    enableVibration: enableVibration ?? false,
    sound: sound == null ? null : UriAndroidNotificationSound(sound),
  );
}

void main() {
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

    test('描述不符 → 重建', () {
      expect(
        shouldRecreateChannel(_current(description: '旧描述'), _target()),
        isTrue,
      );
    });

    test('声音是历史自带音 plai_notify → 重建（一次性迁移）', () {
      expect(
        shouldRecreateChannel(
          _current(
            sound: const RawResourceAndroidNotificationSound('plai_notify')
                .sound,
          ),
          _target(),
        ),
        isTrue,
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
