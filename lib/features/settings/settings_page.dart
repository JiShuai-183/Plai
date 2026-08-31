import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../routes/app_routes.dart';
import '../../services/notifications/notification_scheduler.dart';
import '../../services/notifications/notification_providers.dart';
import '../../theme/theme_controller.dart';
import 'settings_providers.dart';

/// 设置页：分组列表。
///
/// 分组：
/// - 提醒：通知总开关、上课提醒提前量、保活引导入口；
/// - 外观：主题（跟随系统 / 浅色 / 深色）；
/// - 节次时间表编辑入口；
/// - 数据：备份 / 恢复入口。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  /// 通知总开关（缺省视为开启，见 [NotificationSettingsKeys.enabled]）。
  bool _notificationsEnabled = true;

  /// 上课提醒提前量（分钟）。
  int _advanceMin = NotificationSettingsKeys.defaultClassAdvanceMin;

  /// 节次数量（用于节次时间表入口副标题）。
  int _periodCount = 0;

  /// 首次数据是否加载完成。
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  /// 读取设置到本地状态；数据库不可用（如 widget 测试环境）时回退默认值。
  Future<void> _loadSettings() async {
    bool enabled = true;
    int advance = NotificationSettingsKeys.defaultClassAdvanceMin;
    int periodCount = 0;
    try {
      final settings = ref.read(settingsRepositoryProvider);
      final String? enabledRaw =
          await settings.getValue(NotificationSettingsKeys.enabled);
      enabled = enabledRaw != 'false';
      final String? advanceRaw =
          await settings.getValue(NotificationSettingsKeys.classAdvanceMin);
      advance = int.tryParse(advanceRaw ?? '') ??
          NotificationSettingsKeys.defaultClassAdvanceMin;
      final periods =
          await ref.read(settingsTimetableRepoProvider).getPeriods();
      periodCount = periods.length;
    } catch (_) {
      // 保持默认值。
    }
    if (!mounted) return;
    setState(() {
      _notificationsEnabled = enabled;
      _advanceMin = advance;
      _periodCount = periodCount;
      _loading = false;
    });
  }

  // ------------------------------------------------------------ 通知开关

  Future<void> _onNotificationsChanged(bool value) async {
    final settings = ref.read(settingsRepositoryProvider);
    final scheduler = ref.read(notificationSchedulerProvider);
    final service = ref.read(notificationServiceProvider);

    if (value) {
      // 首次开启先申请通知权限（Android 13+ 弹系统授权框）。
      final bool granted = await service.requestPermissions();

      await settings.setValue(NotificationSettingsKeys.enabled, 'true');
      if (!mounted) return;
      setState(() => _notificationsEnabled = true);

      // 首次开启提醒 → 进入国内 ROM 保活引导页。
      final bool showGuide = await scheduler.shouldShowKeepAliveGuide();
      if (!mounted) return;
      if (granted && showGuide) {
        Navigator.of(context).pushNamed(AppRoutes.keepAliveGuide);
      }
      await _safeReschedule();
    } else {
      await settings.setValue(NotificationSettingsKeys.enabled, 'false');
      if (!mounted) return;
      setState(() => _notificationsEnabled = false);
      await _safeCancelAll();
    }
  }

  /// 全量重排提醒（通知开启 / 提前量 / 节次 / 恢复后调用），失败不阻断设置。
  Future<void> _safeReschedule() async {
    try {
      await ref.read(notificationSchedulerProvider).rescheduleAll();
    } catch (_) {
      if (mounted) _showSnack('提醒重排失败，请稍后重试');
    }
  }

  Future<void> _safeCancelAll() async {
    try {
      await ref.read(notificationSchedulerProvider).cancelAll();
    } catch (_) {
      if (mounted) _showSnack('取消提醒失败，请稍后重试');
    }
  }

  // ------------------------------------------------------------ 提前量

  Future<void> _pickAdvanceMin() async {
    final int? picked = await showDialog<int>(
      context: context,
      builder: (BuildContext context) {
        return SimpleDialog(
          title: const Text('上课提醒提前量'),
          children: [
            for (final int m in const [0, 5, 10, 15, 30, 60])
              ListTile(
                title: Text(m == 0 ? '准时（0 分钟）' : '$m 分钟'),
                trailing: m == _advanceMin
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.of(context).pop(m),
              ),
          ],
        );
      },
    );
    if (picked == null || picked == _advanceMin || !mounted) return;
    setState(() => _advanceMin = picked);
    await ref
        .read(settingsRepositoryProvider)
        .setValue(NotificationSettingsKeys.classAdvanceMin, '$picked');
    await _safeReschedule();
  }

  // ------------------------------------------------------------ 主题

  Future<void> _pickThemeMode() async {
    final ThemeMode current = ref.read(themeModeProvider);
    final ThemeMode? picked = await showDialog<ThemeMode>(
      context: context,
      builder: (BuildContext context) {
        return SimpleDialog(
          title: const Text('主题'),
          children: [
            for (final (ThemeMode mode, String label)
                in const [
                  (ThemeMode.system, '跟随系统'),
                  (ThemeMode.light, '浅色'),
                  (ThemeMode.dark, '深色'),
                ])
              ListTile(
                title: Text(label),
                trailing: mode == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(mode),
              ),
          ],
        );
      },
    );
    if (picked == null || picked == current || !mounted) return;
    await ref.read(themeModeProvider.notifier).setThemeMode(picked);
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const _SectionHeader('提醒'),
                SwitchListTile(
                  title: const Text('通知提醒'),
                  subtitle: const Text('开启后按课表与日程发送本地提醒'),
                  secondary: const Icon(Icons.notifications_outlined),
                  value: _notificationsEnabled,
                  onChanged: _onNotificationsChanged,
                ),
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text('上课提醒提前量'),
                  subtitle: Text(
                    _advanceMin == 0 ? '准时提醒' : '上课前 $_advanceMin 分钟提醒',
                  ),
                  onTap: _pickAdvanceMin,
                ),
                ListTile(
                  leading: const Icon(Icons.phone_android_outlined),
                  title: const Text('提醒保活引导'),
                  subtitle: const Text('国内 ROM 防后台被杀设置指引'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      Navigator.of(context).pushNamed(AppRoutes.keepAliveGuide),
                ),
                const _SectionHeader('外观'),
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('主题'),
                  subtitle: Text(_themeLabel(ref.watch(themeModeProvider))),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _pickThemeMode,
                ),
                const _SectionHeader('节次时间表'),
                ListTile(
                  leading: const Icon(Icons.schedule_outlined),
                  title: const Text('节次时间表'),
                  subtitle: Text('共 $_periodCount 节 · 编辑各节起止时间'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await Navigator.of(context)
                        .pushNamed(AppRoutes.periodsEdit);
                    if (mounted) _loadSettings(); // 返回后刷新节次数量
                  },
                ),
                const _SectionHeader('数据'),
                ListTile(
                  leading: const Icon(Icons.storage_outlined),
                  title: const Text('备份与恢复'),
                  subtitle: const Text('导出 .plai 备份 / 从备份恢复'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await Navigator.of(context).pushNamed(AppRoutes.backup);
                    if (mounted) _loadSettings(); // 返回后刷新设置与节次
                  },
                ),
              ],
            ),
    );
  }

  static String _themeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return '浅色';
      case ThemeMode.dark:
        return '深色';
      case ThemeMode.system:
        return '跟随系统';
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 分组列表标题。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.labelLarge
            ?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}
