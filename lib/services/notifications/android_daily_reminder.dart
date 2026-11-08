import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
// 22.3.0 的原生 Daily 支持明确起始日，公共 zonedSchedule(time) 却丢弃日期。
// 复用同版本序列化器，避免通知渠道/声音参数偏离插件公共入口。升级插件须复核。
// ignore: implementation_imports
import 'package:flutter_local_notifications/src/platform_specifics/android/method_channel_mappers.dart';
// ignore: implementation_imports
import 'package:flutter_local_notifications/src/tz_datetime_mapper.dart';
import 'package:timezone/timezone.dart' as tz;

/// flutter_local_notifications 22.3.0 Android wire 的窄适配。
///
/// 原生枚举 ScheduledNotificationRepeatFrequency.Daily = 0；不传 time
/// match 组件，否则原生入口会按今天重算。后续由系统按首触发自然日 +1 天重排，
/// 进程关闭与重启恢复仍有效。不涉及定时器、额外通知 ID 或滚动窗口。
abstract final class AndroidDailyReminder {
  static const _channel = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );

  static Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime firstAt,
    required String payload,
    required AndroidNotificationDetails details,
    required AndroidScheduleMode mode,
  }) => _channel.invokeMethod<void>('zonedSchedule', <String, Object?>{
    'id': id,
    'title': title,
    'body': body,
    'payload': payload,
    'platformSpecifics': <String, Object?>{
      ...details.toMap(),
      'scheduleMode': mode.name,
    },
    ...firstAt.toMap(),
    'scheduledNotificationRepeatFrequency': 0,
  });
}
