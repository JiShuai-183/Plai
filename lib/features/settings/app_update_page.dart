import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/app_update/app_update_flow.dart';
import '../../services/app_update/app_update_service.dart';

/// 版本信息与手动检查入口。
///
/// 下载、安装和重启仍全部复用统一更新流程，并且只有用户点击对应按钮后才会
/// 执行，页面本身不会静默下载或安装。
class AppUpdatePage extends StatefulWidget {
  const AppUpdatePage({super.key});

  @override
  State<AppUpdatePage> createState() => _AppUpdatePageState();
}

class _AppUpdatePageState extends State<AppUpdatePage> {
  String _version = '正在读取…';
  String _status = '点击下方按钮检查新版本。';
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadVersion());
  }

  Future<void> _loadVersion() async {
    final AppUpdateService service = AppUpdateService();
    try {
      final String version = await service.currentVersion();
      if (mounted) setState(() => _version = version);
    } catch (_) {
      if (mounted) setState(() => _version = '未知');
    } finally {
      service.dispose();
    }
  }

  Future<void> _checkNow() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _status = '正在检查更新…';
    });
    final ManualUpdateCheckResult result = await runManualUpdateCheck(context);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _status = switch (result) {
        ManualUpdateCheckResult.upToDate => '当前已是最新版本。',
        ManualUpdateCheckResult.updateAvailable => '已发现新版本，请按提示下载更新。',
        ManualUpdateCheckResult.failed => '检查失败，请确认网络后重试。',
        ManualUpdateCheckResult.cancelled => '检查已取消。',
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('检查更新')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.system_update_outlined,
                  size: 56,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 20),
                Text(
                  'Plai $_version',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: _checking ? null : _checkNow,
                  icon: _checking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: Text(_checking ? '正在检查' : '检查更新'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
