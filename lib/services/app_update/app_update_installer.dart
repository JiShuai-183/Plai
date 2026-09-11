import 'dart:io';

import 'package:flutter/services.dart';
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
}
