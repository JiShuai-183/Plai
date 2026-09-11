import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_update_completion.dart';
import 'app_update_installer.dart';
import 'app_update_service.dart';

/// 启动后统一的更新交互。检查仅通知；下载和安装都必须由用户显式点击。
Future<void> runStartupUpdateFlow(BuildContext context) async {
  await Future<void>.delayed(const Duration(seconds: 3));
  if (!context.mounted) return;
  final AppUpdateService service = AppUpdateService();
  try {
    final AppUpdateCompletion? completion = await AppUpdateCompletionStore()
        .consumeForVersion(await service.currentVersion());
    if (!context.mounted) return;
    if (completion != null) {
      await _showCompletion(context, completion);
    }
    if (!context.mounted) return;
    final AppUpdateCandidate? candidate = await service.checkForUpdate();
    if (candidate != null && context.mounted) {
      await _showAvailable(context, service, candidate);
    }
  } finally {
    service.dispose();
  }
}

/// 设置页触发的即时检查。
///
/// 与启动检查共用同一份受信任清单、版本比较、下载与安装流程；区别仅在于
/// 不等待三秒，并把“已经是最新版本”和联网失败明确反馈给用户。
Future<ManualUpdateCheckResult> runManualUpdateCheck(
  BuildContext context,
) async {
  final AppUpdateService service = AppUpdateService();
  try {
    final AppUpdateCandidate? candidate = await service.checkForUpdate();
    if (!context.mounted) return ManualUpdateCheckResult.cancelled;
    if (candidate == null) {
      _showMessage(context, '已是最新版本。');
      return ManualUpdateCheckResult.upToDate;
    }
    await _showAvailable(context, service, candidate);
    return ManualUpdateCheckResult.updateAvailable;
  } on AppUpdateException catch (error) {
    if (context.mounted) _showMessage(context, error.message);
    return ManualUpdateCheckResult.failed;
  } catch (_) {
    if (context.mounted) _showMessage(context, '检查更新失败，请稍后重试。');
    return ManualUpdateCheckResult.failed;
  } finally {
    service.dispose();
  }
}

enum ManualUpdateCheckResult { upToDate, updateAvailable, failed, cancelled }

Future<void> _showCompletion(
  BuildContext context,
  AppUpdateCompletion completion,
) => showDialog<void>(
  context: context,
  builder: (BuildContext context) => AlertDialog(
    title: Text('已更新至 ${completion.version}'),
    content: _UpdateText(
      notes: completion.notes,
      announcement: completion.announcement,
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('知道了'),
      ),
    ],
  ),
);

Future<void> _showAvailable(
  BuildContext context,
  AppUpdateService service,
  AppUpdateCandidate candidate,
) async {
  // 先等待用户在“发现新版本”弹窗中的选择；下载工作必须在这个 Future 内继续，
  // 这样外层启动流程不会提前 dispose 掉 [service] 的 HTTP 客户端。
  final bool? download = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text('发现新版本 ${candidate.version}'),
      content: _UpdateText(
        notes: candidate.notes,
        announcement: candidate.announcement,
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('稍后更新'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(candidate.requiresStore ? '前往 App Store' : '下载更新'),
        ),
      ],
    ),
  );
  if (download != true || !context.mounted) return;

  if (candidate.requiresStore) {
    final bool opened = await AppUpdateInstaller().openAppStore(
      candidate.storeUrl!,
    );
    if (context.mounted && !opened) {
      _showMessage(context, '无法打开 App Store。');
    }
    return;
  }
  final File? file = await showDialog<File>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext _) =>
        _DownloadDialog(service: service, candidate: candidate),
  );
  if (file == null || !context.mounted) return;
  await _prepareInstall(context, candidate, file);
}

Future<void> _prepareInstall(
  BuildContext context,
  AppUpdateCandidate candidate,
  File file,
) async {
  if (candidate.platform == AppUpdatePlatform.android) {
    final bool? install = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('更新已下载'),
        content: const Text('接下来会打开 Android 系统安装页，请确认“更新/安装”。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('稍后安装'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('打开安装页'),
          ),
        ],
      ),
    );
    if (install != true) return;
    await AppUpdateCompletionStore().markPending(candidate);
    try {
      final bool opened = await AppUpdateInstaller().openAndroidInstaller(file);
      if (context.mounted && opened) {
        _showMessage(context, '请在系统页面确认更新；若先要求授权，请返回后再次点击安装。');
      }
    } on PlatformException {
      if (context.mounted) _showMessage(context, '无法打开系统安装页。');
    }
  }
}

void _showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

class _UpdateText extends StatelessWidget {
  const _UpdateText({required this.notes, required this.announcement});
  final String notes;
  final String announcement;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (notes.isNotEmpty) ...<Widget>[
          const Text('更新内容'),
          const SizedBox(height: 6),
          Text(notes),
        ],
        if (notes.isNotEmpty && announcement.isNotEmpty)
          const SizedBox(height: 16),
        if (announcement.isNotEmpty) ...<Widget>[
          const Text('公告'),
          const SizedBox(height: 6),
          Text(announcement),
        ],
      ],
    ),
  );
}

class _DownloadDialog extends StatefulWidget {
  const _DownloadDialog({required this.service, required this.candidate});
  final AppUpdateService service;
  final AppUpdateCandidate candidate;

  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  AppUpdateProgress? _progress;
  String? _error;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      unawaited(_download());
    }
  }

  Future<void> _download() async {
    try {
      final File file = await widget.service.download(
        widget.candidate,
        onProgress: (AppUpdateProgress progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (mounted) Navigator.of(context).pop(file);
    } on AppUpdateException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '下载更新失败，请稍后重试。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppUpdateProgress? progress = _progress;
    return AlertDialog(
      title: const Text('正在下载更新'),
      content: SizedBox(
        width: 280,
        child: _error == null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  LinearProgressIndicator(value: progress?.fraction),
                  const SizedBox(height: 12),
                  Text(
                    progress == null
                        ? '正在连接更新服务器…'
                        : '${_formatBytes(progress.downloadedBytes)} / ${_formatBytes(progress.totalBytes)}',
                  ),
                ],
              )
            : Text(_error!),
      ),
      actions: _error == null
          ? const <Widget>[]
          : <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
            ],
    );
  }
}

String _formatBytes(int value) {
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
}
