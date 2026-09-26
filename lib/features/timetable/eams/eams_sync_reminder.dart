import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/semester.dart';
import '../../../data/repositories/settings_repository.dart';
import '../../../routes/app_routes.dart';
import '../timetable_providers.dart';

/// 「课表同步提醒」设置的键的**单一来源**。
///
/// 本类只声明键常量，不含读写逻辑；设置页（plai-settings）直接 import 本文件
/// 取常量，避免键名漂移。所有值均为**字符串**（设置表是纯字符串 KV）：
/// - [lastAt] / [nextRemindAt] 存 int 毫秒时间戳的十进制字符串；
/// - [lastSemesterId] 存 int 学期 id 的十进制字符串；
/// - [enabled] 存 `'1'` / `'0'`，**键缺失视作开**。
abstract final class EamsSyncKeys {
  /// 上一次**成功拉取**课表的时刻（int 毫秒字符串）。
  static const String lastAt = 'eams.sync.lastAt';

  /// 上一次成功拉取时对应的学期 id（int 字符串）。
  static const String lastSemesterId = 'eams.sync.lastSemesterId';

  /// 下一次允许提醒的时刻（int 毫秒字符串）；节流用。
  static const String nextRemindAt = 'eams.sync.nextRemindAt';

  /// 提醒总开关：`'1'` 开 / `'0'` 关；**键缺失视作开**。
  static const String enabled = 'eams.sync.reminder.enabled';
}

/// 课表同步提醒：距上次成功拉取教务处课表满 7 天（或本学期从未同步过）时，
/// 弹一次不可点外部关闭的悬浮弹窗，引导用户去「从教务导入课表」页同步。
///
/// 判定真值表（顺序即优先级，见任务冻结接口）：
/// 1. `enabled` 键存在且 != '1' → 不弹；
/// 2. 当前学期为 null（全新无学期）→ 不弹；
/// 3. `lastSemesterId != 学期.id`（本学期从未同步）或
///    `lastAt` 存在且 `now - lastAt >= 7 天` → 需要提醒；
/// 4. 需要提醒但 `nextRemindAt` 存在且 `now < nextRemindAt` → 节流，不弹；
/// 5. 需要提醒但弹窗守卫命中 → 不弹，**且不写** [EamsSyncKeys.nextRemindAt]；
/// 6. 弹窗；无论点哪个按钮，**先**写 `nextRemindAt = now + 7 天`，再执行按钮动作；
/// 7. 点「立即同步」→ `pushNamed(AppRoutes.eamsImport, arguments: true)`——
///    目标页会据此**自动执行一次拉取**（等价手动点「拉取课表」，不自动导入）。
///
/// 与通知无关：本功能纯应用内弹窗，不接 plai-notify。
class EamsSyncReminder {
  EamsSyncReminder({
    required this.settings,
    required this.ref,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final ISettingsRepository settings;
  final Ref ref;

  /// 可注入时钟（测试控时钟）。
  final DateTime Function() _now;

  /// 提醒间隔：每 7 天最多提醒一次。
  static const Duration remindInterval = Duration(days: 7);

  /// 弹窗文案（一字不改，含 `7 天` 前的空格与全角标点）。
  static const String dialogTitle = '课表同步提醒';
  static const String dialogBody = '已经 7 天没有同步教务处课表了，建议同步一下课表';
  static const String laterButtonLabel = '下次提醒';
  static const String syncNowButtonLabel = '立即同步';

  /// 重入锁：弹窗展示期间不允许再次进入。
  bool _showing = false;

  /// 在合适的时机检查并（按需）弹一次同步提醒。
  ///
  /// 由壳层（plai-scaffold，Phase 2）调用；本方法**尽力而为**，
  /// 任何读取 / 弹窗异常都静默吞掉，绝不影响调用方。
  Future<void> maybeRemind(BuildContext context) async {
    try {
      // 1) 总开关：键缺失视作开。
      final String? enabledValue = await settings.getValue(EamsSyncKeys.enabled);
      if (enabledValue != null && enabledValue != '1') return;

      // 2) 无当前学期 → 不弹。
      final Semester? semester = await ref.read(currentSemesterProvider.future);
      if (semester == null) return;
      final String semesterId = semester.id?.toString() ?? '';

      // 3) 是否需要提醒。
      final String? lastSemesterId = await settings.getValue(
        EamsSyncKeys.lastSemesterId,
      );
      bool should = lastSemesterId != semesterId;
      if (!should) {
        final DateTime? lastAt = _parseMs(
          await settings.getValue(EamsSyncKeys.lastAt),
        );
        if (lastAt != null &&
            _now().difference(lastAt) >= remindInterval) {
          should = true;
        }
      }
      if (!should) return;

      // 4) 节流：上次提醒未到点 → 不弹（也不改写 nextRemindAt）。
      final DateTime? next = _parseMs(
        await settings.getValue(EamsSyncKeys.nextRemindAt),
      );
      if (next != null && _now().isBefore(next)) return;

      // 5) 守卫：命中即跳过，且不写 nextRemindAt。
      if (_showing) return;
      if (!context.mounted) return;
      final ModalRoute<Object?>? route = ModalRoute.of(context);
      if (route?.isCurrent != true) return;
      if (route?.settings.name == AppRoutes.eamsImport) return;

      // 6) 弹窗。
      _showing = true;
      try {
        final DateTime firedAt = _now();
        final bool? action = await showDialog<bool>(
          context: context,
          // 不可点外部关闭 —— 否则「计一次提醒」无法归档。
          barrierDismissible: false,
          builder: (BuildContext dialogContext) => PopScope(
            // 不可用返回键关闭（同 barrierDismissible: false 的意图）。
            canPop: false,
            child: AlertDialog(
              title: const Text(dialogTitle),
              content: const Text(dialogBody),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text(laterButtonLabel),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text(syncNowButtonLabel),
                ),
              ],
            ),
          ),
        );
        // 先记下一次提醒（7 天后），再执行按钮动作 —— 这样即便跳转后
        // 拉取失败 / 用户放弃，也已在 7 天后才再次提醒。
        await _writeNextRemindAt(firedAt.add(remindInterval));
        if (action == true && context.mounted) {
          // 不等待目标页返回：提醒任务到此为止。
          unawaited(
            Navigator.of(
              context,
            ).pushNamed(AppRoutes.eamsImport, arguments: true),
          );
        }
      } finally {
        _showing = false;
      }
    } catch (_) {
      // 同步提醒是尽力而为，任何失败都不影响调用方。
    }
  }

  /// 拉取成功打点：记录本次同步时刻与学期 id。
  ///
  /// 仅在**拉取成功且已有当前学期**时调用；失败会被静默吞掉，
  /// 绝不能影响已成功的拉取与预览（与 `_saveCredentials` 同一精神）。
  Future<void> recordSync(int semesterId) async {
    try {
      final DateTime at = _now();
      await settings.setValue(
        EamsSyncKeys.lastAt,
        at.millisecondsSinceEpoch.toString(),
      );
      await settings.setValue(
        EamsSyncKeys.lastSemesterId,
        semesterId.toString(),
      );
    } catch (_) {
      // 打点失败静默吞掉。
    }
  }

  Future<void> _writeNextRemindAt(DateTime at) async {
    try {
      await settings.setValue(
        EamsSyncKeys.nextRemindAt,
        at.millisecondsSinceEpoch.toString(),
      );
    } catch (_) {
      // 打点失败静默吞掉。
    }
  }

  static DateTime? _parseMs(String? raw) {
    if (raw == null) return null;
    final int? ms = int.tryParse(raw);
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }
}

/// 全局单例：壳层（plai-scaffold）只调这一行取实例。
final eamsSyncReminderProvider = Provider<EamsSyncReminder>((ref) {
  return EamsSyncReminder(
    settings: ref.watch(settingsRepositoryProvider),
    ref: ref,
  );
});
