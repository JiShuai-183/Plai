import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// 安装通道的结果。**本类绝不抛异常**：真机上任何失败都要落成一句可读原因，
/// 更不能冒泡到外层变成「检查更新失败」（2.3.0 用户实测踩到过）。
enum AppUpdateInstallStatus {
  /// 系统安装页已弹出。
  installerOpened,

  /// 缺少「安装未知应用」授权，已把用户送到系统授权页。
  permissionRequired,

  /// 通道未注册 / 平台异常，安装页没有打开。
  failed,
}

class AppUpdateInstallResult {
  const AppUpdateInstallResult(this.status, [this.detail = '']);

  final AppUpdateInstallStatus status;

  /// 失败原因（含异常类型与平台返回的 code/message），直接展示给用户排查。
  final String detail;

  bool get launched =>
      status == AppUpdateInstallStatus.installerOpened ||
      status == AppUpdateInstallStatus.permissionRequired;
}

class AppUpdateInstaller {
  static const MethodChannel _channel = MethodChannel('plai/app_update');

  /// Android 的系统安装器必定要求用户确认；返回值只表示「安装页或授权页已打开」。
  Future<AppUpdateInstallResult> openAndroidInstaller(File apk) async {
    try {
      final Object? result = await _channel.invokeMethod<Object>(
        'installApk',
        <String, Object>{'path': apk.path},
      );
      if (result == 'installerOpened') {
        return const AppUpdateInstallResult(
          AppUpdateInstallStatus.installerOpened,
        );
      }
      if (result == 'permissionRequired') {
        return const AppUpdateInstallResult(
          AppUpdateInstallStatus.permissionRequired,
        );
      }
      return AppUpdateInstallResult(
        AppUpdateInstallStatus.failed,
        '安装通道返回了未知结果：$result',
      );
    } on PlatformException catch (error) {
      return AppUpdateInstallResult(
        AppUpdateInstallStatus.failed,
        '系统安装器返回错误（${error.code}）：${error.message ?? '无详细信息'}',
      );
    } on MissingPluginException catch (error) {
      return AppUpdateInstallResult(
        AppUpdateInstallStatus.failed,
        '安装通道未注册（MissingPluginException）：${error.message ?? '无详细信息'}',
      );
    } catch (error) {
      return AppUpdateInstallResult(
        AppUpdateInstallStatus.failed,
        '打开安装页时出现未预期异常（${error.runtimeType}）：$error',
      );
    }
  }

  /// 安装通道不可用时的兜底：把 APK 地址交给浏览器，用户可自行下载后安装。
  Future<bool> openBrowserInstall(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  Future<bool> openAppStore(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);
}
