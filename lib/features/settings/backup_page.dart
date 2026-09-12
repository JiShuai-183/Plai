import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/backup/backup_service.dart';
import '../../data/models/date_utils.dart';
import '../../services/notifications/notification_providers.dart';
import '../../theme/theme_controller.dart';
import '../schedule/schedule_providers.dart';
import '../timetable/timetable_providers.dart' hide settingsRepositoryProvider;
import 'settings_providers.dart';

/// 备份相关设置键。
abstract final class BackupSettingsKeys {
  /// 最近一次成功导出的时间（ISO8601），用于展示「最近备份时间」。
  static const String lastBackupAt = 'settings.last_backup_at';
}

/// 备份与恢复页。
///
/// - 导出：把课表 / 日程 / 设置打包为 `.plai` 文件保存到用户指定位置；
/// - 导入：选择 `.plai` 文件 → 预览摘要 → 选择「合并 / 覆盖」策略 →
///   覆盖需二次输入「覆盖」强确认 → 恢复并重排提醒。
class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});

  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage> {
  DateTime? _lastBackupAt;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadLastBackupAt();
  }

  Future<void> _loadLastBackupAt() async {
    DateTime? last;
    try {
      final String? raw = await ref
          .read(settingsRepositoryProvider)
          .getValue(BackupSettingsKeys.lastBackupAt);
      last = DateTime.tryParse(raw ?? '');
    } catch (_) {
      last = null;
    }
    if (!mounted) return;
    setState(() => _lastBackupAt = last);
  }

  // ------------------------------------------------------------ 导出

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final BackupService backup = ref.read(backupServiceProvider);
      final Map<String, dynamic> json = await backup.exportToJson();
      final String content =
          const JsonEncoder.withIndent('  ').convert(json);
      final Uri? uri = await FilePicker.saveFile(
        fileName: 'plai-backup-${dateOnlyToString(DateTime.now())}.plai',
        bytes: Uint8List.fromList(utf8.encode(content)),
        type: FileType.custom,
        allowedExtensions: ['plai'],
      );
      if (uri == null) {
        // 用户取消保存。
        return;
      }
      await ref.read(settingsRepositoryProvider).setValue(
            BackupSettingsKeys.lastBackupAt,
            DateTime.now().toIso8601String(),
          );
      if (!mounted) return;
      setState(() => _lastBackupAt = DateTime.now());
      _showSnack('备份已导出');
    } catch (e) {
      if (mounted) _showSnack('导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------ 导入

  Future<void> _import() async {
    final PlatformFile? file = await FilePicker.pickFile(
      dialogTitle: '选择 .plai 备份文件',
      type: FileType.custom,
      allowedExtensions: ['plai'],
    );
    if (file == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final BackupService backup = ref.read(backupServiceProvider);
      final String content = utf8.decode(await file.readAsBytes());
      final Map<String, dynamic> json =
          jsonDecode(content) as Map<String, dynamic>;
      final BackupPreview preview = backup.preview(json);

      if (!mounted) return;
      setState(() => _busy = false);

      // 预览 + 选择策略 + 强确认。
      final RestoreStrategy? strategy = await _chooseStrategyAndConfirm(preview);
      if (strategy == null || !mounted) return;

      setState(() => _busy = true);
      await backup.restore(json, strategy: strategy);
      // 数据变更：失效各模块缓存，让课表 / 今日 / 主题按恢复后的数据重建。
      ref.invalidate(themeModeProvider);
      ref.invalidate(semestersProvider);
      ref.invalidate(currentSemesterProvider);
      ref.invalidate(coursesProvider);
      ref.invalidate(periodsProvider);
      ref.invalidate(holidaysProvider);
      ref.invalidate(classAdvanceMinProvider);
      ref.invalidate(tasksProvider);
      ref.invalidate(todayViewProvider);
      // 恢复后按新设置 / 数据全量重排提醒。
      try {
        await ref.read(notificationSchedulerProvider).rescheduleAll();
      } catch (_) {
        // 提醒重排失败不阻断恢复结果。
      }
      if (!mounted) return;
      _showSnack(
        strategy == RestoreStrategy.overwrite ? '已覆盖恢复' : '已合并恢复',
      );
    } on BackupFormatException catch (e) {
      if (mounted) _showSnack('备份文件无效：${e.message}');
    } catch (e) {
      if (mounted) _showSnack('恢复失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 展示预览摘要并让用户选择恢复策略；返回 null 表示取消。
  Future<RestoreStrategy?> _chooseStrategyAndConfirm(
      BackupPreview preview) async {
    final RestoreStrategy? strategy = await showDialog<RestoreStrategy>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('恢复备份'),
          content: Text(
            '导出时间：${_previewDate(preview.exportedAt)}\n'
            '学期 ${preview.semesterCount} · 课程 ${preview.courseCount} · '
            '节次 ${preview.periodCount} · 停课 ${preview.holidayCount}\n'
            '任务 ${preview.taskCount} · 设置 ${preview.settingCount} 项\n'
            '${_credentialNotice(preview.credentialCount)}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context)
                  .pop(RestoreStrategy.merge),
              child: const Text('合并恢复'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context)
                  .pop(RestoreStrategy.overwrite),
              child: const Text('覆盖恢复'),
            ),
          ],
        );
      },
    );
    if (strategy == null) return null;

    if (strategy == RestoreStrategy.merge) {
      if (!mounted) return null;
      final bool? ok = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('确认合并恢复'),
            content: const Text(
              '备份中的学期 / 课程 / 任务将按业务键去重后并入当前数据，'
              '现有数据保留，设置以备份为准（AI 密钥等凭据除外，始终保留在本机）。'
              '确定继续吗？',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('合并'),
              ),
            ],
          );
        },
      );
      return ok == true ? RestoreStrategy.merge : null;
    }

    // 覆盖：强确认 + 二次输入确认。
    if (!mounted) return null;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (_) => const _OverwriteConfirmDialog(),
    );
    return ok == true ? RestoreStrategy.overwrite : null;
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('最近备份', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    _lastBackupAt == null
                        ? '尚未备份，建议换机 / 学期末前导出一次'
                        : '${dateOnlyToString(_lastBackupAt!)} 已导出',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.upload_outlined),
            title: const Text('导出备份'),
            subtitle: const Text('将课表、日程、设置打包为 .plai 文件'),
            trailing: const Icon(Icons.chevron_right),
            enabled: !_busy,
            onTap: _export,
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('从备份恢复'),
            subtitle: const Text('导入 .plai 文件并预览、合并或覆盖'),
            trailing: const Icon(Icons.chevron_right),
            enabled: !_busy,
            onTap: _import,
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  /// 预览里的凭据提示：老备份含凭据键时明示将被忽略。
  static String _credentialNotice(int count) {
    if (count > 0) {
      return '备份含 $count 项 AI 密钥凭据，恢复时将忽略（AI 密钥等凭据保留在本机）';
    }
    return 'AI 密钥等凭据保留在本机，不写入备份';
  }

  static String _previewDate(DateTime? t) {
    if (t == null) return '未知';
    final DateTime local = t.toLocal();
    final String hh = local.hour.toString().padLeft(2, '0');
    final String mm = local.minute.toString().padLeft(2, '0');
    return '${dateOnlyToString(local)} $hh:$mm';
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 覆盖恢复的强确认对话框：必须输入「覆盖」才能确认。
class _OverwriteConfirmDialog extends StatefulWidget {
  const _OverwriteConfirmDialog();

  @override
  State<_OverwriteConfirmDialog> createState() =>
      _OverwriteConfirmDialogState();
}

class _OverwriteConfirmDialogState extends State<_OverwriteConfirmDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _matched = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    setState(() => _matched = value.trim() == '覆盖');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('覆盖恢复 · 强确认'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '覆盖恢复会清空当前全部数据（课表 / 日程 / 设置）并用备份替换，'
            'AI 密钥等凭据保留在本机不受影响。此操作不可撤销。',
          ),
          const SizedBox(height: 12),
          const Text('请输入「覆盖」以继续：'),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            autofocus: true,
            onChanged: _onChanged,
            decoration: const InputDecoration(hintText: '覆盖'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _matched
              ? () => Navigator.of(context).pop(true)
              : null,
          child: const Text('确认覆盖'),
        ),
      ],
    );
  }
}
