import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../../routes/app_routes.dart';
import '../../routes/route_registry.dart';
import 'navigator.dart';
import 'notification_ids.dart';
import 'notification_payload.dart';

/// 本地通知服务：初始化、通知渠道、权限申请、通知点击深链分发。
///
/// 属于 `lib/services/notifications/`（plai-notify 专属）。timetable / schedule
/// / settings 模块**不要直接 import 本文件以外的插件 API**，统一通过
/// [NotificationService] 与 `NotificationScheduler` 交互（见《提醒调度接口.md》）。
class NotificationService {
  NotificationService._();

  /// 全局单例。在 `main()` 启动时调用 [initialize]。
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// 初始化是否完成（幂等）。
  bool _initialized = false;

  /// 进行中的初始化 Future（并发去重）。
  Future<void>? _initializing;

  /// 冷启动 / 运行中待分发的深链意图（Navigator 尚未就绪时暂存）。
  NotificationIntent? _pendingIntent;

  /// 是否已完成初始化。
  bool get initialized => _initialized;

  /// 底层插件实例（供 [NotificationScheduler] 调度使用）。
  FlutterLocalNotificationsPlugin get plugin => _plugin;

  /// 初始化插件（幂等，可并发安全调用）。
  ///
  /// 职责：加载时区、注册开机恢复接收器、创建默认通知渠道、
  /// 解析「由通知拉起」的冷启动深链并在首帧后分发。
  Future<void> initialize() {
    if (_initialized) return Future.value();
    return _initializing ??= _doInitialize().then((_) {
      _initialized = true;
      _initializing = null;
    }).catchError((Object e) {
      // 初始化失败不应拖垮 App 启动；记录并允许后续重试。
      _initializing = null;
      debugPrint('NotificationService.initialize 失败: $e');
    });
  }

  Future<void> _doInitialize() async {
    tz.initializeTimeZones();
    // 目标用户在国内，本地时区固定为 Asia/Shanghai；时区数据缺失时保持默认。
    try {
      tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
    } catch (_) {
      // 忽略：默认 UTC 不影响单次精确调度（按绝对时间戳触发）。
    }

    const InitializationSettings settings = InitializationSettings(
      android: AndroidInitializationSettings('ic_notification'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );

    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onDidReceiveNotificationResponse,
    );

    await _createChannels();
    await _dispatchColdStart();
  }

  /// 创建/校正通知渠道（系统默认提示音）。
  ///
  /// 渠道属性（震动 / 声音 / 重要度）创建后不可改，且删除重建会抹掉用户对
  /// 渠道的设置（部分 ROM 上反复重建还会把渠道降为「不重要通知」，导致
  /// 无提示音也不震动）。因此只对「缺失」或「属性与预期不符」的渠道做
  /// 删除重建：
  /// - 老安装的默认渠道曾是震动=true → 检测不符后重建为不震动；
  /// - 渠道被系统降为低重要度（不重要通知）→ 重建为高重要度；
  /// - 属性一致 → 原样保留，不再每次启动删除重建。
  /// 双渠道按「提醒震动」开关在调度时选用（不震 [defaultChannelId] /
  /// 震 [vibrateChannelId]）。
  Future<void> _createChannels() async {
    final AndroidFlutterLocalNotificationsPlugin? android = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    const List<AndroidNotificationChannel> desired = [
      AndroidNotificationChannel(
        NotificationIds.defaultChannelId,
        NotificationIds.defaultChannelName,
        description: NotificationIds.defaultChannelDescription,
        importance: Importance.high,
        playSound: true,
        enableVibration: false,
      ),
      AndroidNotificationChannel(
        NotificationIds.vibrateChannelId,
        NotificationIds.vibrateChannelName,
        description: NotificationIds.vibrateChannelDescription,
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      ),
    ];
    final List<AndroidNotificationChannel> existing =
        await android.getNotificationChannels() ?? const [];
    final Map<String, AndroidNotificationChannel> byId = {
      for (final AndroidNotificationChannel ch in existing) ch.id: ch,
    };
    for (final AndroidNotificationChannel target in desired) {
      final AndroidNotificationChannel? current = byId[target.id];
      if (current == null) {
        await android.createNotificationChannel(target);
        continue;
      }
      final bool mismatch =
          current.enableVibration != target.enableVibration ||
              current.playSound != target.playSound ||
              current.importance != target.importance;
      if (mismatch) {
        await android.deleteNotificationChannel(channelId: target.id);
        await android.createNotificationChannel(target);
      }
    }
  }

  /// 申请通知相关权限（幂等，可反复调用）。
  ///
  /// - Android 13+（API 33+）：`POST_NOTIFICATIONS` 弹系统授权框；
  /// - Android 12+（API 31+）：`SCHEDULE_EXACT_ALARM` 精确闹钟授权
  ///   （拉起系统设置页，用户在系统内开启）；
  /// - iOS / macOS：`requestPermissions`（alert / badge / sound）。
  ///
  /// 返回通知权限是否已授予（无法判定时按已授予处理）。
  Future<bool> requestPermissions() async {
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      final IOSFlutterLocalNotificationsPlugin? ios = _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>();
      final bool? granted =
          await ios?.requestPermissions(alert: true, badge: true, sound: true);
      return granted ?? true;
    }

    final AndroidFlutterLocalNotificationsPlugin? android = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return true;
    final bool? granted = await android.requestNotificationsPermission();
    // 精确闹钟：声明了 SCHEDULE_EXACT_ALARM 时弹系统设置引导；
    // 声明了 USE_EXACT_ALARM（Android 14+）时系统默认授予，本调用为 no-op。
    await android.requestExactAlarmsPermission();
    return granted ?? true;
  }

  /// 通知权限是否已授予（未初始化 / 无法判定时按已授予处理）。
  Future<bool> areNotificationsEnabled() async {
    final AndroidFlutterLocalNotificationsPlugin? android = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    return await android?.areNotificationsEnabled() ?? true;
  }

  /// 当前是否可精确调度通知（`SCHEDULE_EXACT_ALARM` 是否授予）。
  Future<bool> canScheduleExactAlarms() async {
    final AndroidFlutterLocalNotificationsPlugin? android = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    return await android?.canScheduleExactNotifications() ?? true;
  }

  // ---------------------------------------------------------------- 深链

  /// 冷启动：App 由通知拉起时，在首帧后分发深链。
  Future<void> _dispatchColdStart() async {
    final NotificationAppLaunchDetails? details =
        await _plugin.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return;
    final String? payload = details.notificationResponse?.payload;
    if (payload == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dispatchIntent(payload);
    });
  }

  /// 运行中点击通知的回调。
  void _onDidReceiveNotificationResponse(NotificationResponse response) {
    final String? payload = response.payload;
    if (payload == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dispatchIntent(payload);
    });
  }

  /// 根据 payload 跳转到对应页面。
  ///
  /// 目标路由尚未登记（如 timetableWeek / taskDetail 由课表/日程模块
  /// 后续登记）时，回退到根路由，保证不崩溃。
  void _dispatchIntent(String payload) {
    final NotificationIntent? intent = NotificationPayload.parse(payload);
    if (intent != null) {
      _pendingIntent = intent;
    }

    final NavigatorState? navigator = appNavigatorKey.currentState;
    if (navigator == null) return; // 首帧尚未构建，交由下一次分发重试

    final NotificationIntent? target = _pendingIntent;
    _pendingIntent = null;
    if (target == null) return;

    switch (target.type) {
      case NotificationIntentType.classReminder:
        final int? week = target.week;
        if (week != null && routeRegistry.containsKey(AppRoutes.timetableWeek)) {
          navigator.pushNamed(AppRoutes.timetableWeek, arguments: week);
          return;
        }
        break;
      case NotificationIntentType.taskReminder:
        final int? taskId = target.taskId;
        if (taskId != null && routeRegistry.containsKey(AppRoutes.taskDetail)) {
          navigator.pushNamed(AppRoutes.taskDetail, arguments: taskId);
          return;
        }
        break;
    }
    navigator.pushNamed(AppRoutes.root);
  }
}
