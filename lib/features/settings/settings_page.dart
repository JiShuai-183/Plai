import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../routes/app_routes.dart';
import '../../services/audio/complete_sound.dart';
import '../../services/notifications/notification_scheduler.dart';
import '../../services/notifications/notification_providers.dart';
import '../../theme/theme_controller.dart';
import 'settings_providers.dart';

/// 设置页：分组列表。
///
/// 分组：
/// - 提醒：通知总开关、上课提醒提前量、保活引导入口；
/// - 外观：主题（跟随系统 / 浅色 / 深色）；
/// - 课表设置：入口 ListTile（节次时间表 / 课表颜色 / 样式 见 [TimetableSettingsPage]）；
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

  /// 课程提醒震动 / 日程提醒震动（默认不震动）。
  bool _classVibrate = false;
  bool _taskVibrate = false;

  /// 日程完成提示音设置值（空 = 不播放；`asset:key` = 内置；否则本地文件路径）。
  String _completeSound = '';

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
    try {
      final settings = ref.read(settingsRepositoryProvider);
      final String? enabledRaw = await settings.getValue(
        NotificationSettingsKeys.enabled,
      );
      enabled = enabledRaw != 'false';
      final String? advanceRaw = await settings.getValue(
        NotificationSettingsKeys.classAdvanceMin,
      );
      advance =
          int.tryParse(advanceRaw ?? '') ??
          NotificationSettingsKeys.defaultClassAdvanceMin;
      _classVibrate =
          await settings.getValue(NotificationSettingsKeys.classVibrate) ==
          'true';
      _taskVibrate =
          await settings.getValue(NotificationSettingsKeys.taskVibrate) ==
          'true';
      _completeSound =
          await settings.getValue(NotificationSettingsKeys.completeSound) ?? '';
    } catch (_) {
      // 保持默认值。
    }
    if (!mounted) return;
    setState(() {
      _notificationsEnabled = enabled;
      _advanceMin = advance;
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

  // ------------------------------------------------------------ 提醒震动

  /// 切换课程提醒震动：存键 → 重排换渠道。
  Future<void> _onClassVibrateChanged(bool value) async {
    setState(() => _classVibrate = value);
    await ref
        .read(settingsRepositoryProvider)
        .setValue(NotificationSettingsKeys.classVibrate, '$value');
    await _safeReschedule();
  }

  /// 切换日程提醒震动：存键 → 重排换渠道。
  Future<void> _onTaskVibrateChanged(bool value) async {
    setState(() => _taskVibrate = value);
    await ref
        .read(settingsRepositoryProvider)
        .setValue(NotificationSettingsKeys.taskVibrate, '$value');
    await _safeReschedule();
  }

  // ------------------------------------------------------------ 完成提示音

  /// 提示音展示名：内置预设显示其名；本地文件取文件名。
  String _completeSoundName() {
    if (isBuiltinCompleteSound(_completeSound)) {
      return builtinCompleteSoundLabel(_completeSound);
    }
    final int sep = _completeSound.lastIndexOf(RegExp('[\\\\/]'));
    return sep >= 0 ? _completeSound.substring(sep + 1) : _completeSound;
  }

  /// 选择日程完成提示音：弹出底部选择（内置预设 / 从本地文件选）。
  Future<void> _chooseCompleteSound() async {
    final String? choice = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final MapEntry<String, String> entry
                  in kBuiltinCompleteSounds.entries)
                ListTile(
                  leading: const Icon(Icons.auto_awesome),
                  title: Text(entry.value),
                  subtitle: const Text('内置提示音'),
                  onTap: () => Navigator.of(context).pop('asset:${entry.key}'),
                ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.library_music_outlined),
                title: const Text('从本地文件选择…'),
                subtitle: const Text('复制进应用目录，源文件移动不影响'),
                onTap: () => Navigator.of(context).pop('__file__'),
              ),
            ],
          ),
        );
      },
    );
    if (choice == null || !mounted) return;
    if (choice == '__file__') {
      await _pickCompleteSound();
      return;
    }
    setState(() => _completeSound = choice);
    await ref
        .read(settingsRepositoryProvider)
        .setValue(NotificationSettingsKeys.completeSound, choice);
    _showSnack('已设置完成提示音');
  }

  /// 选择本地音频文件作为日程完成提示音（复制进应用目录，防源文件移动失效）。
  Future<void> _pickCompleteSound() async {
    final PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(type: FileType.audio);
    } catch (_) {
      _showSnack('打开文件选择器失败');
      return;
    }
    final String? source = picked?.path;
    if (source == null || !mounted) return;
    try {
      final Directory docs = await getApplicationDocumentsDirectory();
      final Directory soundDir = Directory('${docs.path}/plai_sounds')
        ..createSync(recursive: true);
      final String ext = source.contains('.')
          ? source.substring(source.lastIndexOf('.'))
          : '.audio';
      final String target = '${soundDir.path}/complete_sound$ext';
      await File(source).copy(target);
      await ref
          .read(settingsRepositoryProvider)
          .setValue(NotificationSettingsKeys.completeSound, target);
      if (!mounted) return;
      setState(() => _completeSound = target);
      _showSnack('已设置日程完成提示音');
    } catch (_) {
      _showSnack('设置提示音失败，请重试');
    }
  }

  /// 清除日程完成提示音。
  Future<void> _clearCompleteSound() async {
    setState(() => _completeSound = '');
    await ref
        .read(settingsRepositoryProvider)
        .setValue(NotificationSettingsKeys.completeSound, '');
    _showSnack('已清除日程完成提示音');
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
                trailing: m == _advanceMin ? const Icon(Icons.check) : null,
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
    final PlaiThemeMode current = ref.read(themeModeProvider);
    final PlaiThemeMode? picked = await showDialog<PlaiThemeMode>(
      context: context,
      builder: (BuildContext context) {
        return SimpleDialog(
          title: const Text('主题'),
          children: [
            // 顺序即 PlaiThemeMode 声明顺序：跟随系统 / 浅色 / 白色 / 深色。
            for (final PlaiThemeMode mode in PlaiThemeMode.values)
              ListTile(
                title: Text(mode.label),
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
                SwitchListTile(
                  title: const Text('课程提醒震动'),
                  subtitle: const Text('上课提醒通知附带震动反馈'),
                  secondary: const Icon(Icons.vibration_outlined),
                  value: _classVibrate,
                  onChanged: _onClassVibrateChanged,
                ),
                SwitchListTile(
                  title: const Text('日程提醒震动'),
                  subtitle: const Text('日程与待办提醒通知附带震动反馈'),
                  secondary: const Icon(Icons.vibration_outlined),
                  value: _taskVibrate,
                  onChanged: _onTaskVibrateChanged,
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
                  leading: const Icon(Icons.music_note_outlined),
                  title: const Text('日程完成提示音'),
                  subtitle: Text(
                    _completeSound.isEmpty
                        ? '未设置（完成任务时无音频反馈）'
                        : _completeSoundName(),
                  ),
                  trailing: _completeSound.isEmpty
                      ? const Icon(Icons.chevron_right)
                      : IconButton(
                          tooltip: '清除提示音',
                          icon: const Icon(Icons.close),
                          onPressed: _clearCompleteSound,
                        ),
                  onTap: _chooseCompleteSound,
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
                const _SectionHeader('AI'),
                ListTile(
                  leading: const Icon(Icons.smart_toy_outlined),
                  title: const Text('AI 服务'),
                  subtitle: const Text('对话模型 · 允许 AI 操作 · OCR'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      Navigator.of(context)
                          .pushNamed(AppRoutes.aiServiceSettings),
                ),
                const _SectionHeader('课表设置'),
                ListTile(
                  leading: const Icon(Icons.calendar_month_outlined),
                  title: const Text('课表设置'),
                  subtitle: const Text('课表颜色 · 状态色 · 节次时间'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      Navigator.of(context)
                          .pushNamed(AppRoutes.timetableSettings),
                ),
                const _SectionHeader('数据'),
                ListTile(
                  leading: const Icon(Icons.storage_outlined),
                  title: const Text('备份与恢复'),
                  subtitle: const Text('导出 .plai 备份 / 从备份恢复'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await Navigator.of(context).pushNamed(AppRoutes.backup);
                    if (mounted) _loadSettings(); // 返回后刷新设置
                  },
                ),
                const _SectionHeader('关于'),
                ListTile(
                  leading: const Icon(Icons.system_update_outlined),
                  title: const Text('检查更新'),
                  subtitle: const Text('检查新版本、更新内容与公告'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      Navigator.of(context).pushNamed(AppRoutes.appUpdate),
                ),
              ],
            ),
    );
  }

  static String _themeLabel(PlaiThemeMode mode) => mode.label;

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
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
