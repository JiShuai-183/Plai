import 'dart:io';

import 'package:flutter/services.dart';

/// Android 自身的已安装 APK；分包安装与不支持的平台返回 null，走全量。
class AppUpdatePlatformFiles {
  static const _channel = MethodChannel('plai/app_update');

  static Future<File?> installedApk() async {
    if (!Platform.isAndroid) return null;
    try {
      final path = await _channel.invokeMethod<String>('getInstalledApkPath');
      return path == null || path.isEmpty ? null : File(path);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
