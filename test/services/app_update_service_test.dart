import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plai/services/app_update/app_update_service.dart';

void main() {
  const String manifestPath = '/downloads/plai/latest.json';

  AppUpdateService serviceFor(
    Object manifest, {
    AppUpdateConfig config = const AppUpdateConfig(
      origin: 'https://updates.example.com',
      fallbackOrigins: <String>[],
    ),
    http.Client? client,
  }) => AppUpdateService(
    client:
        client ??
        MockClient((http.Request request) async {
          expect(request.url.toString(), 'https://updates.example.com$manifestPath');
          return http.Response(
            jsonEncode(manifest),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
    config: config,
    versionLoader: () async => '2.1.2',
    platform: AppUpdatePlatform.android,
  );

  Map<String, Object> manifestWithVersion(String version) => <String, Object>{
    'version': version,
    'notes': '修复课表显示。',
    'announcement': '请及时更新。',
    'assets': <String, Object>{
      'android': <String, Object>{
        'name': 'Plai-android-$version.apk',
        'path': 'releases/$version/Plai-android-$version.apk',
        'size': 1024,
        'sha256': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      },
    },
  };

  test('只接受固定源、合法路径和更高版本的 Android 更新包', () async {
    final AppUpdateCheckResult result =
        await serviceFor(manifestWithVersion('2.1.3')).checkForUpdate();

    expect(result.status, AppUpdateCheckStatus.updateAvailable);
    final AppUpdateCandidate candidate = result.candidate!;
    expect(candidate.version, '2.1.3');
    expect(candidate.asset!.path, 'releases/2.1.3/Plai-android-2.1.3.apk');
    expect(candidate.downloadOrigin!.base, 'https://updates.example.com');
  });

  test('低版本不算更新，且必须是「已是最新」而不是失败', () async {
    final AppUpdateCheckResult result =
        await serviceFor(manifestWithVersion('2.1.2')).checkForUpdate();

    expect(result.status, AppUpdateCheckStatus.upToDate);
    expect(result.candidate, isNull);
  });

  test('路径穿越等非法清单必须报失败，不能伪装成已是最新', () async {
    final AppUpdateCheckResult badPath = await serviceFor(<String, Object>{
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

    expect(badPath.status, AppUpdateCheckStatus.failed);
    expect(badPath.candidate, isNull);
    expect(badPath.message, isNotEmpty);
  });

  test('联网失败必须报失败（历史 bug：曾一律显示已是最新版本）', () async {
    final AppUpdateService service = serviceFor(
      manifestWithVersion('2.1.3'),
      client: MockClient((http.Request request) async {
        throw http.ClientException('connection refused', request.url);
      }),
    );

    final AppUpdateCheckResult result = await service.checkForUpdate();

    expect(result.status, AppUpdateCheckStatus.failed);
    expect(result.candidate, isNull);
    expect(result.message, contains('连接'));
    service.dispose();
  });

  test('主源不可达时回退到备源，并用备源下载产物', () async {
    const AppUpdateConfig config = AppUpdateConfig(
      origin: 'https://primary.example.com',
      fallbackOrigins: <String>['https://fallback.example.com'],
    );
    final AppUpdateService service = serviceFor(
      manifestWithVersion('2.1.3'),
      config: config,
      client: MockClient((http.Request request) async {
        if (request.url.host == 'primary.example.com') {
          throw http.ClientException('dns failure', request.url);
        }
        expect(request.url.host, 'fallback.example.com');
        expect(request.url.path, manifestPath);
        return http.Response(
          jsonEncode(manifestWithVersion('2.1.3')),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );

    final AppUpdateCheckResult result = await service.checkForUpdate();

    expect(result.status, AppUpdateCheckStatus.updateAvailable);
    expect(
      result.candidate!.downloadOrigin!.base,
      'https://fallback.example.com',
    );
    service.dispose();
  });

  test('更新通道只有新服务器 IP 直连，不含旧服务器或任何域名回退', () {
    const AppUpdateConfig config = AppUpdateConfig();
    final AppUpdateOrigin primary = config.origins.first;

    expect(primary.base, 'https://43.142.93.106');
    expect(primary.uri.host, '43.142.93.106');
    expect(config.manifestUri.toString(),
        'https://43.142.93.106/downloads/plai/latest.json');
    // 2.3.1 起唯一受信源就是该 IP：不许再出现旧服务器域名。
    expect(config.origins.map((AppUpdateOrigin o) => o.base),
        <String>['https://43.142.93.106']);
    expect(config.fallbackOrigins, isEmpty);
    // 下载地址必须始终落在受信源上。
    expect(
      config.urlForPath('releases/2.3.0/Plai-android-2.3.0.apk').toString(),
      'https://43.142.93.106/downloads/plai/releases/2.3.0/Plai-android-2.3.0.apk',
    );
  });
}
