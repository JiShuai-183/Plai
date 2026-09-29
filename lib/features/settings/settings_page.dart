import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../routes/app_routes.dart';
import '../../theme/theme_controller.dart';

/// 设置页：分组列表。
///
/// 分组：
/// - 提醒：入口 ListTile（通知开关 / 提前量 / 提示音 / 提醒保护 见
///   [ReminderSettingsPage]）；
/// - 外观：主题（跟随系统 / 浅色 / 深色）；
/// - 课表设置：入口 ListTile（节次时间表 / 课表颜色 / 样式 见 [TimetableSettingsPage]）；
/// - 数据：备份 / 恢复入口。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
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
      body: ListView(
        children: [
          const _SectionHeader('提醒'),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('提醒设置'),
            subtitle: const Text('通知开关 · 提前量 · 提示音 · 提醒保护'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () =>
                Navigator.of(context).pushNamed(AppRoutes.reminderSettings),
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
                Navigator.of(context).pushNamed(AppRoutes.aiServiceSettings),
          ),
          const _SectionHeader('课表设置'),
          ListTile(
            leading: const Icon(Icons.calendar_month_outlined),
            title: const Text('课表设置'),
            subtitle: const Text('课表颜色 · 状态色 · 节次时间'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () =>
                Navigator.of(context).pushNamed(AppRoutes.timetableSettings),
          ),
          const _SectionHeader('数据'),
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: const Text('备份与恢复'),
            subtitle: const Text('导出 .plai 备份 / 从备份恢复'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).pushNamed(AppRoutes.backup),
          ),
          const _SectionHeader('关于'),
          ListTile(
            leading: const Icon(Icons.system_update_outlined),
            title: const Text('检查更新'),
            subtitle: const Text('检查新版本、更新内容与公告'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).pushNamed(AppRoutes.appUpdate),
          ),
        ],
      ),
    );
  }

  static String _themeLabel(PlaiThemeMode mode) => mode.label;
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
