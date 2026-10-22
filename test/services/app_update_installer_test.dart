import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/services/app_update/app_update_installer.dart';

/// 安装通道的回归测试：2.3.0 真机上点「打开安装页」直接报「检查更新失败」——
/// 根因是通道异常（PlatformException / MissingPluginException）没被接住，
/// 冒泡到上层被当成「检查更新失败」。这里锁定「绝不抛异常、必须带原因」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('plai/app_update');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory tempDir;
  late File apk;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plai_installer_test');
    apk = File('${tempDir.path}/Plai-android-2.3.2.apk')
      ..writeAsBytesSync(<int>[0]);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('安装页打开时返回 installerOpened，并把 APK 路径传给平台侧', () async {
    String? received;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'installApk');
      received = (call.arguments as Map<Object?, Object?>)['path'] as String?;
      return 'installerOpened';
    });

    final AppUpdateInstallResult result =
        await AppUpdateInstaller().openAndroidInstaller(apk);

    expect(result.status, AppUpdateInstallStatus.installerOpened);
    expect(result.launched, isTrue);
    expect(result.detail, isEmpty);
    expect(received, apk.path);
  });

  test('缺少未知来源授权时返回 permissionRequired', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      return 'permissionRequired';
    });

    final AppUpdateInstallResult result =
        await AppUpdateInstaller().openAndroidInstaller(apk);

    expect(result.status, AppUpdateInstallStatus.permissionRequired);
    expect(result.launched, isTrue);
  });

  test('平台返回错误码时如实带出 code 与 message，而不是静默失败', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      throw PlatformException(code: 'install_failed', message: 'boom');
    });

    final AppUpdateInstallResult result =
        await AppUpdateInstaller().openAndroidInstaller(apk);

    expect(result.status, AppUpdateInstallStatus.failed);
    expect(result.launched, isFalse);
    expect(result.detail, contains('install_failed'));
    expect(result.detail, contains('boom'));
  });

  test('平台通道未注册（Release 混淆 / 插件缺失）时返回 MissingPluginException 原因',
      () async {
    messenger.setMockMethodCallHandler(channel, null);

    final AppUpdateInstallResult result =
        await AppUpdateInstaller().openAndroidInstaller(apk);

    expect(result.status, AppUpdateInstallStatus.failed);
    expect(result.detail, contains('MissingPluginException'));
  });

  test('通道返回未知字符串时不抛异常，按失败处理', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      return 'something-else';
    });

    final AppUpdateInstallResult result =
        await AppUpdateInstaller().openAndroidInstaller(apk);

    expect(result.status, AppUpdateInstallStatus.failed);
    expect(result.detail, contains('未知结果'));
  });

  test('平台侧抛出非 PlatformException 时也被接住（测试框架会转成 code=error）',
      () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      throw StateError('unexpected');
    });

    final AppUpdateInstallResult result =
        await AppUpdateInstaller().openAndroidInstaller(apk);

    expect(result.status, AppUpdateInstallStatus.failed);
    expect(result.detail, contains('Bad state: unexpected'));
  });
}
