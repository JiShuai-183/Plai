import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/repositories/eams_credentials_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Android 读写删除均使用同一安全 namespace，系统备份排除对应文件', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final repo = EamsCredentialsRepository();
    await repo.read();
    await repo.save(
      const EamsCredentials(username: 'test', password: 'secret'),
    );
    await repo.clear();
    expect(calls.map((call) => call.method), ['read', 'write', 'delete']);
    for (final call in calls) {
      final options = call.arguments['options'] as Map;
      expect(options['storageNamespace'], 'plai_eams_credentials');
      expect(options['resetOnError'], 'false');
      expect(call.arguments['key'], EamsCredentialsRepository.storageKey);
    }
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    expect(manifest, contains('android:fullBackupContent="@xml/backup_rules"'));
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
    final legacy = File('android/app/src/main/res/xml/backup_rules.xml')
        .readAsStringSync();
    final modern = File(
      'android/app/src/main/res/xml/data_extraction_rules.xml',
    ).readAsStringSync();
    for (final name in [
      'plai_eams_credentials.xml',
      'FlutterSecureKeyStorage:plai_eams_credentials.xml',
      'FlutterSecureStorageConfiguration:plai_eams_credentials.xml',
    ]) {
      final exclusion = '<exclude domain="sharedpref" path="$name" />';
      expect(legacy, contains(exclusion));
      expect(
        modern.split('<cloud-backup>')[1].split('</cloud-backup>')[0],
        contains(exclusion),
      );
      expect(
        modern.split('<device-transfer>')[1].split('</device-transfer>')[0],
        contains(exclusion),
      );
    }
  });

  test('iOS 仅限本机解锁时访问，不同步，三种构建均声明 Keychain entitlement', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final repo = EamsCredentialsRepository();
    await repo.read();
    await repo.save(
      const EamsCredentials(username: 'test', password: 'secret'),
    );
    await repo.clear();
    for (final call in calls) {
      final options = call.arguments['options'] as Map;
      expect(options['accessibility'], 'unlocked_this_device');
      expect(options['synchronizable'], 'false');
      expect(options['accountName'], 'plai.eams.credentials');
    }
    final project = File('ios/Runner.xcodeproj/project.pbxproj')
        .readAsStringSync();
    expect(
      'CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;'.allMatches(
        project,
      ),
      hasLength(3),
    );
    expect(
      File('ios/Runner/Runner.entitlements').readAsStringSync(),
      contains('keychain-access-groups'),
    );
  });

  test('平台存储异常向上层传播，不悄悄降级到明文或返回成功', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => throw PlatformException(code: 'unavailable'),
        );
    final repo = EamsCredentialsRepository();
    await expectLater(repo.read(), throwsA(isA<PlatformException>()));
    await expectLater(
      repo.save(const EamsCredentials(username: 'test', password: 'secret')),
      throwsA(isA<PlatformException>()),
    );
    await expectLater(repo.clear(), throwsA(isA<PlatformException>()));
  });
}
