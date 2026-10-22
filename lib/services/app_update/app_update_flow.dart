import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../shared/plai_toast.dart';
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
    // 启动检查保持静默（失败不打扰首屏，也绝不谎称「已是最新版本」），
    // 但**必须重试**：冷启动后 3 秒时移动网络 / DNS / TLS 握手常常还没就绪，
    // 只试一次就会出现「3 秒后什么都没发生」的真机现象。
    final AppUpdateCheckResult result = await checkForUpdateWithRetry(
      service.checkForUpdate,
      isActive: () => context.mounted,
    );
    if (result.status == AppUpdateCheckStatus.failed) {
      debugPrint('启动更新检查失败：${result.message}');
    }
    final AppUpdateCandidate? candidate = result.candidate;
    if (candidate != null && context.mounted) {
      await _showAvailable(context, service, candidate);
    }
  } finally {
    service.dispose();
  }
}

/// 带退避重试的「检查更新」，供启动检查使用。
///
/// 冷启动后 3 秒时，移动网络、DNS、TLS 握手都可能还没就绪；只试一次的话
/// 检查会失败，而启动检查按设计静默，用户看到的现象就是「什么都不发生」
/// （2.3.2 / 2.3.3 真机反馈）。失败按 [backoff] 依次重试，直到成功或试尽。
Future<AppUpdateCheckResult> checkForUpdateWithRetry(
  Future<AppUpdateCheckResult> Function() attempt, {
  List<Duration> backoff = const <Duration>[
    Duration(seconds: 6),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ],
  bool Function()? isActive,
}) async {
  AppUpdateCheckResult result = await attempt();
  for (final Duration delay in backoff) {
    if (result.status != AppUpdateCheckStatus.failed) return result;
    if (isActive != null && !isActive()) return result;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (isActive != null && !isActive()) return result;
    result = await attempt();
  }
  return result;
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
    final AppUpdateCheckResult result = await service.checkForUpdate();
    if (!context.mounted) return ManualUpdateCheckResult.cancelled;
    switch (result.status) {
      case AppUpdateCheckStatus.upToDate:
        _showMessage(context, '当前已是最新版本。');
        return const ManualUpdateCheckResult(ManualUpdateStatus.upToDate);
      case AppUpdateCheckStatus.updateAvailable:
        await _showAvailable(context, service, result.candidate!);
        return const ManualUpdateCheckResult(
          ManualUpdateStatus.updateAvailable,
        );
      case AppUpdateCheckStatus.failed:
      case AppUpdateCheckStatus.unsupported:
        // 关键修复：网络/证书/清单异常必须如实报错，不能落到「已是最新版本」。
        final String message = result.message.isEmpty
            ? '检查更新失败，请稍后重试。'
            : result.message;
        _showMessage(context, message, kind: PlaiToastKind.error);
        return ManualUpdateCheckResult(ManualUpdateStatus.failed, message);
    }
  } catch (error) {
    // 带上异常类型：真机出问题时要能一眼看出是哪一类失败。
    final String fallback =
        '检查更新失败（${error.runtimeType}），请稍后重试。';
    if (context.mounted) {
      _showMessage(context, fallback, kind: PlaiToastKind.error);
    }
    return ManualUpdateCheckResult(ManualUpdateStatus.failed, fallback);
  } finally {
    service.dispose();
  }
}

enum ManualUpdateStatus { upToDate, updateAvailable, failed, cancelled }

/// 手动检查的结果：状态 + 失败原因（页面直接展示，不再统一成一句「失败」）。
class ManualUpdateCheckResult {
  const ManualUpdateCheckResult(this.status, [this.message = '']);

  final ManualUpdateStatus status;
  final String message;

  static const ManualUpdateCheckResult cancelled = ManualUpdateCheckResult(
    ManualUpdateStatus.cancelled,
  );
}

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
      _showMessage(context, '无法打开 App Store。', kind: PlaiToastKind.error);
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
  try {
    await _prepareInstall(context, service, candidate, file);
  } catch (error) {
    // 安装环节的任何异常都不能冒泡成「检查更新失败」：如实报出类型便于真机排查。
    if (context.mounted) {
      _showMessage(
        context,
        '安装流程异常（${error.runtimeType}）：$error',
        kind: PlaiToastKind.error,
      );
    }
  }
}

Future<void> _prepareInstall(
  BuildContext context,
  AppUpdateService service,
  AppUpdateCandidate candidate,
  File file,
) async {
  if (candidate.platform != AppUpdatePlatform.android) return;
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
  if (install != true || !context.mounted) return;

  // 交接记录只影响「安装完成后」的那张说明弹窗：写失败绝不能拦住安装本身。
  try {
    await AppUpdateCompletionStore().markPending(candidate);
  } catch (_) {}

  // 安装通道自身绝不抛异常，失败会带原因回来（见 AppUpdateInstallResult）。
  final AppUpdateInstallResult result =
      await AppUpdateInstaller().openAndroidInstaller(file);
  if (!context.mounted) return;
  switch (result.status) {
    case AppUpdateInstallStatus.installerOpened:
      _showMessage(context, '请在系统页面确认更新。');
    case AppUpdateInstallStatus.permissionRequired:
      _showMessage(
        context,
        '已打开「安装未知应用」授权页：允许后返回 App，再点一次“打开安装页”。',
      );
    case AppUpdateInstallStatus.failed:
      await _showInstallFailure(context, service, candidate, result.detail);
  }
}

/// 安装通道不可用时的兜底：把 APK 的 HTTPS 地址交给浏览器，用户可手动下载安装。
Future<void> _showInstallFailure(
  BuildContext context,
  AppUpdateService service,
  AppUpdateCandidate candidate,
  String detail,
) async {
  final AppUpdateAsset? asset = candidate.asset;
  final Uri? url = asset == null
      ? null
      : service.config.urlForPath(asset.path, origin: candidate.downloadOrigin);
  final bool? useBrowser = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('无法打开系统安装页'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(detail.isEmpty ? '系统没有响应安装请求。' : detail),
            if (url != null) ...<Widget>[
              const SizedBox(height: 12),
              const Text('可以改用浏览器下载安装包，下载后再打开安装：'),
              const SizedBox(height: 6),
              SelectableText(url.toString()),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('关闭'),
        ),
        if (url != null)
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('用浏览器安装'),
          ),
      ],
    ),
  );
  if (useBrowser != true || url == null) return;
  final bool opened = await AppUpdateInstaller().openBrowserInstall(url);
  if (context.mounted && !opened) {
    _showMessage(
      context,
      '无法打开浏览器，请手动访问：$url',
      kind: PlaiToastKind.error,
    );
  }
}

void _showMessage(BuildContext context, String message,
    {PlaiToastKind kind = PlaiToastKind.normal}) {
  showPlaiToast(context, message, kind: kind);
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
