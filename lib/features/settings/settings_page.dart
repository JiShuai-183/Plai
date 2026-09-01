import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../routes/app_routes.dart';
import '../../services/notifications/notification_scheduler.dart';
import '../../services/notifications/notification_providers.dart';
import '../../theme/theme_controller.dart';
import '../timetable/color_utils.dart';
import '../timetable/timetable_providers.dart'
    hide settingsRepositoryProvider; // 避免与 settings_providers 重名
import '../timetable/timetable_settings_keys.dart';
import 'settings_providers.dart';

/// 设置页：分组列表。
///
/// 分组：
/// - 提醒：通知总开关、上课提醒提前量、保活引导入口；
/// - 外观：主题（跟随系统 / 浅色 / 深色）；
/// - 课表设置：节次时间表、默认课程颜色、状态色总开关、三色、已结束文字淡化/细化；
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

  /// 状态色 / 默认课程颜色色板（与课程表单一致，11 色）。
  static const List<String> _palette = [
    '#E57373', '#F06292', '#BA68C8', '#9575CD', '#64B5F6',
    '#4FC3F7', '#4DB6AC', '#81C784', '#FFB74D', '#A1887F',
    '#9E9E9E',
  ];

  /// 课表设置读取失败时的兜底默认值（与 [TimetableSettingsKeys] 默认一致）。
  static const TimetableStatusSettings _defaultTimetableSettings =
      TimetableStatusSettings(
    statusColorsEnabled: TimetableSettingsKeys.defaultStatusColorsEnabled,
    ongoingColor: TimetableSettingsKeys.defaultStatusColorOngoing,
    upcomingColor: TimetableSettingsKeys.defaultStatusColorUpcoming,
    finishedColor: TimetableSettingsKeys.defaultStatusColorFinished,
    finishedTextFade: TimetableSettingsKeys.defaultFinishedTextFade,
    finishedTextThin: TimetableSettingsKeys.defaultFinishedTextThin,
    defaultCourseColor: TimetableSettingsKeys.defaultCourseColorDefault,
  );

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

  // ------------------------------------------------------------ 课表设置

  /// 写课表设置键（状态色 / 默认课程颜色 / 开关），随后使 provider 失效联动课表页。
  Future<void> _setTimetableValue(String key, String value) async {
    await ref.read(settingsRepositoryProvider).setValue(key, value);
    ref.invalidate(timetableStatusSettingsProvider);
  }

  /// 弹色板：点色即 pop 返回 hex（无色返回 ''）；「恢复默认」pop 返回该键默认值；取消返回 null。
  Future<String?> _pickTimetableColor({
    required String title,
    required String current,
    required String defaultHex,
  }) {
    return showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return SimpleDialog(
          title: Text(title),
          children: [
            ListTile(
              leading: const _ColorDot(''),
              title: const Text('无色'),
              trailing: current.isEmpty ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(context).pop(''),
            ),
            for (final String hex in _palette)
              ListTile(
                leading: _ColorDot(hex),
                title: Text(hex),
                trailing: current == hex ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(hex),
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.restore),
              title: const Text('恢复默认'),
              trailing:
                  current == defaultHex ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(context).pop(defaultHex),
            ),
          ],
        );
      },
    );
  }

  /// 弹色板并把选中值写进对应键（值不变则跳过）。
  Future<void> _onPickColor({
    required String title,
    required String key,
    required String current,
    required String defaultHex,
  }) async {
    final String? picked = await _pickTimetableColor(
      title: title,
      current: current,
      defaultHex: defaultHex,
    );
    if (picked == null || picked == current || !mounted) return;
    await _setTimetableValue(key, picked);
  }

  /// 「课表设置」分组中依赖状态色 provider 的项。
  List<Widget> _buildTimetableStatusTiles(TimetableStatusSettings s) {
    return [
      ListTile(
        leading: const Icon(Icons.palette_outlined),
        title: const Text('默认课程颜色'),
        subtitle: const Text('新建/导入课程初始颜色'),
        trailing: _ColorDot(s.defaultCourseColor),
        onTap: () => _onPickColor(
          title: '默认课程颜色',
          key: TimetableSettingsKeys.defaultCourseColor,
          current: s.defaultCourseColor,
          defaultHex: TimetableSettingsKeys.defaultCourseColorDefault,
        ),
      ),
      SwitchListTile(
        title: const Text('状态色总开关'),
        subtitle: Text(
          s.statusColorsEnabled ? '当前周·今天的课按状态显示颜色' : '全部恢复课程自选颜色',
        ),
        value: s.statusColorsEnabled,
        onChanged: (bool v) => _setTimetableValue(
          TimetableSettingsKeys.statusColorsEnabled,
          '$v',
        ),
      ),
      ListTile(
        title: const Text('正在上颜色'),
        trailing: _ColorDot(s.ongoingColor),
        onTap: () => _onPickColor(
          title: '正在上颜色',
          key: TimetableSettingsKeys.statusColorOngoing,
          current: s.ongoingColor,
          defaultHex: TimetableSettingsKeys.defaultStatusColorOngoing,
        ),
      ),
      ListTile(
        title: const Text('还未上颜色'),
        trailing: _ColorDot(s.upcomingColor),
        onTap: () => _onPickColor(
          title: '还未上颜色',
          key: TimetableSettingsKeys.statusColorUpcoming,
          current: s.upcomingColor,
          defaultHex: TimetableSettingsKeys.defaultStatusColorUpcoming,
        ),
      ),
      ListTile(
        title: const Text('已结束颜色'),
        trailing: _ColorDot(s.finishedColor),
        onTap: () => _onPickColor(
          title: '已结束颜色',
          key: TimetableSettingsKeys.statusColorFinished,
          current: s.finishedColor,
          defaultHex: TimetableSettingsKeys.defaultStatusColorFinished,
        ),
      ),
      SwitchListTile(
        title: const Text('已结束文字淡化'),
        subtitle: const Text('课程名与地点变淡灰'),
        value: s.finishedTextFade,
        onChanged: (bool v) => _setTimetableValue(
          TimetableSettingsKeys.finishedTextFade,
          '$v',
        ),
      ),
      SwitchListTile(
        title: const Text('已结束文字细化'),
        subtitle: const Text('课程名字重变细'),
        value: s.finishedTextThin,
        onChanged: (bool v) => _setTimetableValue(
          TimetableSettingsKeys.finishedTextThin,
          '$v',
        ),
      ),
    ];
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
                const _SectionHeader('课表设置'),
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
                // 状态色 / 默认课程颜色 / 已结束文字样式（provider 不可用时兜底默认值）。
                ...ref.watch(timetableStatusSettingsProvider).when(
                  loading: () => const [
                    ListTile(
                      leading: Icon(Icons.palette_outlined),
                      title: Text('课表设置加载中…'),
                    ),
                  ],
                  error: (_, _) =>
                      _buildTimetableStatusTiles(_defaultTimetableSettings),
                  data: (settings) => _buildTimetableStatusTiles(settings),
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

/// 课程色小块：hex 非空为实心圆；空（无色）为空心圆 + block 图标。
class _ColorDot extends StatelessWidget {
  const _ColorDot(this.hex);

  final String hex;

  static const double _size = 28;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (hex.isEmpty) {
      return Container(
        width: _size,
        height: _size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: scheme.outline),
        ),
        child: Icon(
          Icons.block,
          color: scheme.onSurfaceVariant,
          size: _size * 0.5,
        ),
      );
    }
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        color: colorFromHex(hex),
        shape: BoxShape.circle,
      ),
    );
  }
}
