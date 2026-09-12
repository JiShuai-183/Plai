import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
// 用 latest_10y（±10 年时区规则）而非 latest_all：后者含全部历史规则，
// 初始化时要构造更大的时区表，同步开销明显更高。本 App 只调度近期提醒，
// 10 年跨度远超所需。
import 'package:timezone/data/latest_10y.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../../routes/app_routes.dart';
import '../../routes/route_registry.dart';
import 'navigator.dart';
import 'notification_ids.dart';
import 'notification_payload.dart';

/// 已废弃的两个遗留渠道 id（旧版按「震不震动」拆分）。
///
/// 换渠道标准后会无条件删除这两个渠道。删除渠道会清掉其上已调度 / 已展示的
/// 通知，故依赖「App 冷启动必执行 `rescheduleAll()`」把提醒重排到新渠道
/// （详见 [NotificationIds] 的说明）。删除不存在的渠道是 no-op，天然幂等。
const List<String> _legacyChannelIds = <String>[
  'plai_reminders',
  'plai_reminders_vib',
];

/// 判断已有渠道 [current] 与期望渠道 [target] 属性是否不符、需要删除重建。
/// [current] 为 null（渠道不存在）时返回 true。
///
/// **声音比对规则**：仅当 [target] 显式指定了 `sound` 时才比对声音。目标
/// 未指定声音表示「跟随系统默认音」，而回读值恒为
/// `content://settings/system/notification_sound`（或用户后来自选的音），
/// 与 null 永不相等 —— 若照常比对，会导致每次启动都删掉重建渠道，
/// 反复清空用户在系统里对渠道做的设置（声音 / 重要度 / 震动）。
///
/// 当前本模块所有渠道都不指定 `sound`（跟随系统默认音），故声音实际不参与
/// 比对；保留该分支是为将来某渠道需固定自带音时仍能正确判定。
///
/// **历史自带音迁移已移除**：旧版曾在此处识别渠道里残留的 App 自带音
/// `plai_notify` 并强制重建。现在承载旧音的渠道（`plai_reminders*`）已被
/// [_legacyChannelIds] 无条件删除，新渠道 id 不可能带该音，这个分支已成死
/// 代码，故删除以免留下自相矛盾的注释 —— 迁移效果由「删除遗留渠道」覆盖。
///
/// 比对 **重要度 / playSound / enableVibration** 三项。
///
/// **刻意不比对描述**：描述是纯装饰、本 App 从不修改它，比对它收益为零；
/// 一旦某个 ROM 回读描述为 null 或做了截断，就会退化成「每次启动都重建
/// 渠道」，清空用户在系统里对该渠道的设置 —— 正是本判定要避免的病。
/// 不要再把 description 加回比对。
bool shouldRecreateChannel(
  AndroidNotificationChannel? current,
  AndroidNotificationChannel target,
) {
  if (current == null) return true;
  if (current.importance != target.importance ||
      current.playSound != target.playSound ||
      current.enableVibration != target.enableVibration) {
    return true;
  }
  final String? targetSound = target.sound?.sound;
  if (targetSound != null) {
    return (current.sound?.sound ?? '') != targetSound;
  }
  // 目标跟随系统默认音：声音不参与比对。
  return false;
}

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
    // 先让出一轮事件循环：本方法是 async，但调用方（main / 调度器）调用后
    // 若无人 await，await 之前的代码会同步执行；initializeTimeZones 是
    // CPU 密集的同步构造，放在这里会推迟首帧。先 await 一次让调度器能把
    // 首帧画完（调用方通常已延后到首帧后，此处是双保险）。
    await Future<void>.delayed(Duration.zero);
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

  /// 期望的渠道集合（唯一事实来源）。
  ///
  /// 按**内容**划分两条：课表提醒 / 日程提醒。两者属性一致：
  /// `importance: high`、有声音、不震动。**不指定 `sound`** —— 保持「跟随
  /// 系统默认通知音」；**初始 `enableVibration: false`** —— 与旧版默认
  /// （不震动）一致，想震动的人去系统设置里给对应渠道打开。
  static const List<AndroidNotificationChannel> desiredChannels = [
    AndroidNotificationChannel(
      NotificationIds.classChannelId,
      NotificationIds.classChannelName,
      description: NotificationIds.classChannelDescription,
      importance: Importance.high,
      playSound: true,
      enableVibration: false,
    ),
    AndroidNotificationChannel(
      NotificationIds.taskChannelId,
      NotificationIds.taskChannelName,
      description: NotificationIds.taskChannelDescription,
      importance: Importance.high,
      playSound: true,
      enableVibration: false,
    ),
  ];

  /// 创建/校正通知渠道（通知音跟随系统默认），并删除已废弃的遗留渠道。
  ///
  /// 渠道属性（震动 / 声音 / 重要度）创建后不可改，且删除重建会抹掉用户对
  /// 渠道的设置（部分 ROM 上反复重建还会把渠道降为「不重要通知」，导致
  /// 无提示音也不震动）。因此只对「缺失」或「属性与预期不符」的渠道做
  /// 删除重建：
  /// - 渠道缺失 → 创建；
  /// - 渠道被系统降为低重要度（不重要通知）/ 声音开关被改 → 重建为期望值；
  /// - 属性一致 → 原样保留，不再每次启动删除重建。
  ///
  /// **通知音跟随系统默认**：目标渠道不指定 `sound`，插件在 `playSound: true`
  /// 且 `sound` 为空时解析为系统默认通知音 URI；用户可在系统设置里按渠道或
  /// 全局改音。**代价**：若用户把系统默认通知音设为「无 / 静默」，通知就会
  /// 没声音 —— 这是「与系统保持一致」的预期结果，不做兜底。
  ///
  /// **删除遗留渠道**：无条件删除旧版按震动拆分的 [_legacyChannelIds]（删不存在
  /// 的渠道是 no-op，天然幂等）。删除会清掉其上已调度 / 已展示的通知，靠
  /// 「App 冷启动必执行 `rescheduleAll()`」重排到新渠道（见 [NotificationIds]）。
  Future<void> _createChannels() async {
    final AndroidFlutterLocalNotificationsPlugin? android = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    final List<AndroidNotificationChannel> existing =
        await android.getNotificationChannels() ?? const [];
    final Map<String, AndroidNotificationChannel> byId = {
      for (final AndroidNotificationChannel ch in existing) ch.id: ch,
    };
    for (final AndroidNotificationChannel target in desiredChannels) {
      final AndroidNotificationChannel? current = byId[target.id];
      if (shouldRecreateChannel(current, target)) {
        if (current != null) {
          await android.deleteNotificationChannel(channelId: target.id);
        }
        await android.createNotificationChannel(target);
      }
    }
    // 清理旧标准（按震动拆分）下的两个渠道。
    for (final String id in _legacyChannelIds) {
      await android.deleteNotificationChannel(channelId: id);
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
