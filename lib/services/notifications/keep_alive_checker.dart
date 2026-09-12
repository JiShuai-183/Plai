import 'package:flutter/services.dart';

import '../../data/db/app_database.dart';
import '../../data/repositories/settings_repository.dart';
import 'notification_service.dart';

/// 单项检测的三态结果。
///
/// - [ok]：**能确定**已满足；
/// - [notOk]：**能确定**未满足（引导用户去设置）；
/// - [unknown]：无法判定（通道异常 / 反射被系统拦截 / 非 Android）——
///   一律降级到此态让用户自行确认，**绝不给假 ✓**。
enum KeepAliveCheckState { ok, notOk, unknown }

/// 一项保活检查。
class KeepAliveCheckItem {
  const KeepAliveCheckItem({
    required this.id,
    required this.title,
    required this.detail,
    required this.state,
    required this.settingsTarget,
    this.manualConfirmable = false,
  });

  /// 稳定标识（手动确认设置键后缀用它，勿随意改动）。
  final String id;

  /// 展示标题，如「允许自启动」。
  final String title;

  /// 「这一项没做会导致什么」的人话说明。
  final String detail;

  final KeepAliveCheckState state;

  /// 点击「点击设置」时传给原生 `openSettings` 的 target。
  final String settingsTarget;

  /// 是否允许「我已完成」手动确认（仅无法自动检测的项，如自启动）。
  final bool manualConfirmable;
}

/// 品牌：决定展示哪些检查项与哪份保活步骤。
enum KeepAliveBrand {
  xiaomi,
  huawei,
  honor,
  oppo,
  vivo,
  generic;

  /// 是否展示「允许自启动」项（通用品牌没有可跳转的自启动管理页）。
  bool get needsAutoStart => this != KeepAliveBrand.generic;

  /// 由 `Build.MANUFACTURER` 映射品牌；大小写不敏感，未知 / 空串归 [generic]。
  static KeepAliveBrand fromManufacturer(String manufacturer) {
    final String m = manufacturer.trim().toLowerCase();
    if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco')) {
      return KeepAliveBrand.xiaomi;
    }
    if (m.contains('huawei')) return KeepAliveBrand.huawei;
    // hihonor 也含 'honor'；放在 huawei 之后不影响（hihonor 不含 huawei）。
    if (m.contains('honor') || m.contains('hihonor')) return KeepAliveBrand.honor;
    if (m.contains('oppo') || m.contains('oneplus') || m.contains('realme')) {
      return KeepAliveBrand.oppo;
    }
    if (m.contains('vivo') || m.contains('iqoo')) return KeepAliveBrand.vivo;
    return KeepAliveBrand.generic;
  }
}

/// 保活检测器：原生 `plai/keep_alive` 通道 + 已有通知服务的薄封装。
///
/// 所有对外方法**绝不抛**：任何异常都降级为 `unknown` / `null` / `false` ——
/// 检测页自身不能白屏。
class KeepAliveChecker {
  KeepAliveChecker({
    ISettingsRepository? settings,
    NotificationService? service,
    KeepAliveChannelCaller? channelCaller,
  })  : _settings = settings ?? SettingsRepository(AppDatabase.instance),
        _service = service ?? NotificationService.instance,
        _call = channelCaller ?? _platformCall;

  final ISettingsRepository _settings;
  final NotificationService _service;
  final KeepAliveChannelCaller _call;

  /// 原生方法通道名（与 MainActivity.kt 的注册名一致）。
  static const MethodChannel channel = MethodChannel('plai/keep_alive');

  /// 手动确认项的设置键前缀：`notify.keepalive_confirmed.<itemId>`。
  ///
  /// 值为 `'true'` / `'false'`。仅 [KeepAliveCheckItem.manualConfirmable] 的项
  /// 会写；点「检测」时整体清除，避免陈旧的 ✓ 骗人。
  static const String manualConfirmPrefix = 'notify.keepalive_confirmed.';

  /// 用户选择过的品牌设置键（存 [KeepAliveBrand] 的 `name`）。
  ///
  /// 页面按 `getManufacturer()` 自动预选后，用户手改的品牌记在这里，
  /// 下次进页面优先用它。
  static const String brandKey = 'notify.keepalive_brand';

  /// 手动确认的设置键。
  static String manualConfirmKey(String itemId) =>
      '$manualConfirmPrefix$itemId';

  /// 需要「我已完成」手动确认的 item id（无标准 API 可检测）。
  ///
  /// 页面在**「检测」之前**就要恢复这类项的确认状态，此时还没有 item 列表，
  /// 故在这里集中列出，避免页面重复硬编码。
  static const List<String> manualConfirmableIds = <String>['auto_start'];

  // ------------------------------------------------------------ 品牌

  /// 读取用户上次选择的品牌；未选择过返回 null。
  Future<KeepAliveBrand?> readSelectedBrand() async {
    try {
      final String? raw = await _settings.getValue(brandKey);
      if (raw == null) return null;
      for (final KeepAliveBrand brand in KeepAliveBrand.values) {
        if (brand.name == raw) return brand;
      }
    } catch (_) {
      // 降级为未选择。
    }
    return null;
  }

  /// 持久化用户选择的品牌。
  Future<void> writeSelectedBrand(KeepAliveBrand brand) async {
    try {
      await _settings.setValue(brandKey, brand.name);
    } catch (_) {
      // 持久化失败不影响本次使用。
    }
  }

  // ------------------------------------------------------ 手动确认

  /// 读取某项是否被用户手动确认过「我已完成」。
  Future<bool> readManualConfirm(String itemId) async {
    try {
      return await _settings.getValue(manualConfirmKey(itemId)) == 'true';
    } catch (_) {
      return false;
    }
  }

  /// 写入手动确认状态。
  Future<void> writeManualConfirm(String itemId, bool confirmed) async {
    try {
      await _settings.setValue(
        manualConfirmKey(itemId),
        confirmed ? 'true' : 'false',
      );
    } catch (_) {
      // 忽略。
    }
  }

  /// 清除全部手动确认键（点「检测」前调用，避免陈旧 ✓）。
  Future<void> clearManualConfirms() async {
    try {
      final Map<String, String> all = await _settings.getAll();
      for (final String key in all.keys) {
        if (key.startsWith(manualConfirmPrefix)) {
          await _settings.remove(key);
        }
      }
    } catch (_) {
      // 忽略。
    }
  }

  // ------------------------------------------------------------ 检测

  /// 厂商串（用于品牌预选）；失败返回空串。
  Future<String> getManufacturer() async {
    try {
      final Object? value = await _call('getManufacturer', const {});
      return value is String ? value : '';
    } catch (_) {
      return '';
    }
  }

  /// 采集该品牌需要的全部检查项（顺序：自启动 → 电池优化 → 通知 → 精确闹钟；
  /// [KeepAliveBrand.generic] 不含自启动）。
  Future<List<KeepAliveCheckItem>> collectChecks(KeepAliveBrand brand) async {
    final List<KeepAliveCheckItem> items = <KeepAliveCheckItem>[];
    if (brand.needsAutoStart) {
      items.add(await _checkAutoStart());
    }
    items.add(await _checkBatteryOptimization());
    items.add(await _checkNotificationPermission());
    items.add(await _checkExactAlarm());
    return items;
  }

  Future<KeepAliveCheckItem> _checkAutoStart() async {
    KeepAliveCheckState state = KeepAliveCheckState.unknown;
    try {
      final Object? value = await _call('checkAutoStart', const {});
      state = switch (value) {
        'allowed' => KeepAliveCheckState.ok,
        'denied' => KeepAliveCheckState.notOk,
        _ => KeepAliveCheckState.unknown,
      };
    } catch (_) {
      state = KeepAliveCheckState.unknown;
    }
    return KeepAliveCheckItem(
      id: 'auto_start',
      title: '允许自启动',
      detail: '未开启时，划掉 App 后系统会阻止它被拉起，到点不响。'
          '这是「未启动时提醒不响」最常见的原因。',
      state: state,
      settingsTarget: 'autostart',
      manualConfirmable: true,
    );
  }

  Future<KeepAliveCheckItem> _checkBatteryOptimization() async {
    KeepAliveCheckState state = KeepAliveCheckState.unknown;
    try {
      final Object? value = await _call('checkBatteryOptimization', const {});
      if (value is bool) {
        state = value ? KeepAliveCheckState.ok : KeepAliveCheckState.notOk;
      }
    } catch (_) {
      state = KeepAliveCheckState.unknown;
    }
    return KeepAliveCheckItem(
      id: 'battery_optimization',
      title: '忽略电池优化',
      detail: '被电池优化限制时，App 退到后台可能被杀进程，提醒会被延迟或吞掉。'
          '请把 Plai 加入「不受限制 / 不优化」列表。',
      state: state,
      settingsTarget: 'battery',
    );
  }

  Future<KeepAliveCheckItem> _checkNotificationPermission() async {
    KeepAliveCheckState state = KeepAliveCheckState.unknown;
    try {
      state = await _service.areNotificationsEnabled()
          ? KeepAliveCheckState.ok
          : KeepAliveCheckState.notOk;
    } catch (_) {
      state = KeepAliveCheckState.unknown;
    }
    return KeepAliveCheckItem(
      id: 'notification',
      title: '允许通知',
      detail: '系统会拦截 Plai 的所有通知，提醒一定不响。',
      state: state,
      settingsTarget: 'notification',
    );
  }

  Future<KeepAliveCheckItem> _checkExactAlarm() async {
    KeepAliveCheckState state = KeepAliveCheckState.unknown;
    try {
      state = await _service.canScheduleExactAlarms()
          ? KeepAliveCheckState.ok
          : KeepAliveCheckState.notOk;
    } catch (_) {
      state = KeepAliveCheckState.unknown;
    }
    return KeepAliveCheckItem(
      id: 'exact_alarm',
      title: '允许精确闹钟',
      detail: '关掉后提醒仍会触发，但只能非精确调度，可能被系统延迟几分钟到几小时。',
      state: state,
      settingsTarget: 'exactAlarm',
    );
  }

  // ------------------------------------------------------------ 跳转

  /// 打开对应系统设置页；成功（原生确认已 started）返回 true。
  ///
  /// [channelId] 仅在 `target == 'notification'` 时有意义：**非空**时尝试直达
  /// 该通知渠道的系统设置页（如 `NotificationIds.classChannelId` /
  /// `taskChannelId`）。Android 8.0（API 26）起才有「通知渠道」概念，低版本
  /// 原生会自动退回应用级通知页；原生还有「渠道页 → 应用级通知页 → 应用详情页」
  /// 的三级退化链，故失败也不会崩。为空 / null 时**不放入** arguments（不塞
  /// null 值），走应用级通知页。
  ///
  /// 失败 / 异常一律返回 false，绝不抛。
  Future<bool> openSettings(String target, {String? channelId}) async {
    try {
      final Map<String, Object?> arguments = <String, Object?>{'target': target};
      if (channelId != null && channelId.isNotEmpty) {
        arguments['channelId'] = channelId;
      }
      final Object? value = await _call('openSettings', arguments);
      return value == 'opened';
    } catch (_) {
      return false;
    }
  }
}

/// 底层方法通道调用器签名；测试可注入假实现，避免依赖真机 / 插件。
typedef KeepAliveChannelCaller = Future<Object?> Function(
  String method,
  Map<String, Object?> arguments,
);

/// 默认调用器：走原生 `plai/keep_alive` 通道。
Future<Object?> _platformCall(
  String method,
  Map<String, Object?> arguments,
) {
  return KeepAliveChecker.channel.invokeMethod<Object?>(method, arguments);
}
