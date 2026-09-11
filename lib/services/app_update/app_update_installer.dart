import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

class AppUpdateInstaller {
  static const MethodChannel _channel = MethodChannel('plai/app_update');

  /// Android 的系统安装器必定要求用户确认；返回 true 表示安装页或授权页已打开。
  Future<bool> openAndroidInstaller(File apk) async {
    final Object? result = await _channel.invokeMethod<Object>(
      'installApk',
      <String, Object>{'path': apk.path},
    );
    return result == 'installerOpened' || result == 'permissionRequired';
  }

  Future<bool> openAppStore(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  /// 启动独立 PowerShell 交接器，再由调用方退出当前 Windows 进程。
  /// 脚本会等待旧进程结束、校验 ZIP 条目没有路径穿越、覆盖发行文件并启动新版。
  Future<void> restartWindowsAndApply(File archive) async {
    final Directory support = await getApplicationSupportDirectory();
    final Directory updateRoot = Directory(p.join(support.path, 'updates'));
    await updateRoot.create(recursive: true);
    final File script = File(p.join(updateRoot.path, 'apply-update.ps1'));
    final String executable = Platform.resolvedExecutable;
    // Windows PowerShell 5.1 会把无 BOM 的 UTF-8 脚本按本机 ANSI 代码页
    // 读取；脚本含中文错误信息时会导致解析失败。显式写 UTF-8 BOM，保证
    // 所有受支持 Windows 版本都能正确执行交接器。
    final List<int> scriptBytes = <int>[
      0xEF,
      0xBB,
      0xBF,
      ...utf8.encode(
        _windowsScript(
          archive: archive.path,
          installDirectory: p.dirname(executable),
          executable: executable,
        ),
      ),
    ];
    await script.writeAsBytes(scriptBytes, flush: true);
    await Process.start('powershell.exe', <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
      '-WaitForPid',
      pid.toString(),
    ], mode: ProcessStartMode.detached);
  }
}

String _windowsScript({
  required String archive,
  required String installDirectory,
  required String executable,
}) {
  String quote(String value) => "'${value.replaceAll("'", "''")}'";
  return '''
param([int]\$WaitForPid)
\$ErrorActionPreference = 'Stop'
\$archive = ${quote(archive)}
\$installDirectory = ${quote(installDirectory)}
\$executable = ${quote(executable)}
\$log = Join-Path (Split-Path -Parent \$archive) 'apply-update.log'
try {
  Wait-Process -Id \$WaitForPid -ErrorAction SilentlyContinue
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  \$staging = Join-Path ([System.IO.Path]::GetTempPath()) ('plai-update-' + [guid]::NewGuid())
  New-Item -ItemType Directory -Force -Path \$staging | Out-Null
  \$root = [System.IO.Path]::GetFullPath(\$staging) + [System.IO.Path]::DirectorySeparatorChar
  \$zip = [System.IO.Compression.ZipFile]::OpenRead(\$archive)
  try {
    foreach (\$entry in \$zip.Entries) {
      \$target = [System.IO.Path]::GetFullPath((Join-Path \$staging \$entry.FullName))
      if (-not \$target.StartsWith(\$root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '更新压缩包含不安全路径。'
      }
    }
  } finally { \$zip.Dispose() }
  [System.IO.Compression.ZipFile]::ExtractToDirectory(\$archive, \$staging)
  \$children = @(Get-ChildItem -Force -LiteralPath \$staging)
  \$payload = if (\$children.Count -eq 1 -and \$children[0].PSIsContainer) { \$children[0].FullName } else { \$staging }
  Copy-Item -Path (Join-Path \$payload '*') -Destination \$installDirectory -Recurse -Force
  Start-Process -FilePath \$executable
  Remove-Item -LiteralPath \$archive -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath \$staging -Recurse -Force -ErrorAction SilentlyContinue
} catch {
  \$_ | Out-File -LiteralPath \$log -Encoding utf8
}
''';
}
