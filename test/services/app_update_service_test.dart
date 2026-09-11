import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plai/services/app_update/app_update_service.dart';

void main() {
  AppUpdateService serviceFor(Object manifest) => AppUpdateService(
    client: MockClient((http.Request request) async {
      expect(
        request.url.toString(),
        'https://updates.example.com/downloads/plai/latest.json',
      );
      return http.Response(
        jsonEncode(manifest),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }),
    config: const AppUpdateConfig(origin: 'https://updates.example.com'),
    versionLoader: () async => '2.1.2',
    platform: AppUpdatePlatform.android,
  );

  test('只接受固定源、合法路径和更高版本的 Android 更新包', () async {
    const String digest =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final AppUpdateCandidate? candidate = await serviceFor(<String, Object>{
      'version': '2.1.3',
      'notes': '修复课表显示。',
      'announcement': '请及时更新。',
      'assets': <String, Object>{
        'android': <String, Object>{
          'name': 'Plai-android-2.1.3.apk',
          'path': 'releases/2.1.3/Plai-android-2.1.3.apk',
          'size': 1024,
          'sha256': digest,
        },
      },
    }).checkForUpdate();

    expect(candidate, isNotNull);
    expect(candidate!.version, '2.1.3');
    expect(candidate.asset!.path, 'releases/2.1.3/Plai-android-2.1.3.apk');
  });

  test('清单中的路径穿越、低版本和未知字段不触发更新', () async {
    final AppUpdateCandidate? badPath = await serviceFor(<String, Object>{
      'version': '2.1.3',
      'assets': <String, Object>{
        'android': <String, Object>{
          'name': 'Plai.apk',
          'path': 'releases/2.1.3/../outside.apk',
          'size': 1,
          'sha256': sha256.convert(utf8.encode('x')).toString(),
        },
      },
    }).checkForUpdate();
    final AppUpdateCandidate? oldVersion = await serviceFor(<String, Object>{
      'version': '2.1.2',
      'assets': <String, Object>{},
    }).checkForUpdate();

    expect(badPath, isNull);
    expect(oldVersion, isNull);
  });
}
