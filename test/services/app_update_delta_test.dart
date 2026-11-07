import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plai/services/app_update/app_update_service.dart';

List<int> _integer(int value) {
  var remaining = value.abs();
  final bytes = List<int>.generate(8, (_) {
    final next = remaining & 255;
    remaining >>= 8;
    return next;
  });
  if (value < 0) bytes[7] |= 128;
  return bytes;
}

void main() {
  late Directory temp;
  late File base;
  late List<int> original;
  late List<int> target;
  late List<int> patch;
  late Map<String, Object?> manifest;
  late List<String> requests;
  late List<AppUpdateProgress> progress;
  late AppUpdateService service;
  var patchStatus = 200;
  var baseLoads = 0;
  var baseUnavailable = false;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('plai_delta_flow_');
    original = List.filled(2 * 1024 * 1024, 65);
    target = [...original, 66, 67, 68];
    base = File('${temp.path}/installed.apk');
    await base.writeAsBytes(original);
    final control = gzip.encode([
      ..._integer(original.length),
      ..._integer(3),
      ..._integer(0),
    ]);
    final diff = gzip.encode(List.filled(original.length, 0));
    final extra = gzip.encode([66, 67, 68]);
    patch = [
      ...ascii.encode('PLDIFF01'),
      ..._integer(control.length),
      ..._integer(diff.length),
      ..._integer(target.length),
      ...control,
      ...diff,
      ...extra,
    ];
    manifest = {
      'schemaVersion': 1,
      'version': '2.4.2',
      'assets': {
        'android': {
          'name': 'new.apk',
          'path': 'releases/2.4.2/new.apk',
          'size': target.length,
          'sha256': sha256.convert(target).toString(),
          'delta': {
            'format': AppUpdateDelta.format,
            'fromVersion': '2.4.1',
            'fromSize': original.length,
            'fromSha256': sha256.convert(original).toString(),
            'name': 'update.patch',
            'path': 'releases/2.4.2/update.patch',
            'size': patch.length,
            'sha256': sha256.convert(patch).toString(),
          },
        },
      },
    };
    patchStatus = 200;
    baseLoads = 0;
    baseUnavailable = false;
    requests = [];
    progress = [];
    service = AppUpdateService(
      config: const AppUpdateConfig(origin: 'https://updates.example.com'),
      platform: AppUpdatePlatform.android,
      versionLoader: () async => '2.4.1',
      downloadDirectoryLoader: () async => Directory('${temp.path}/updates'),
      baseApkLoader: () async {
        baseLoads++;
        return baseUnavailable ? null : base;
      },
      client: MockClient((request) async {
        requests.add(request.url.path);
        if (request.url.path.endsWith('latest.json')) {
          return http.Response(jsonEncode(manifest), 200);
        }
        if (request.url.path.endsWith('.patch')) {
          return http.Response.bytes(patch, patchStatus);
        }
        return http.Response.bytes(target, 200);
      }),
    );
  });
  tearDown(() async {
    service.dispose();
    await temp.delete(recursive: true);
  });

  Map<String, Object?> asset() =>
      ((manifest['assets'] as Map)['android'] as Map).cast();
  Map<String, Object?> delta() => (asset()['delta'] as Map).cast();

  void useClient(
    http.Client client, {
    Duration idle = const Duration(seconds: 30),
  }) {
    service.dispose();
    service = AppUpdateService(
      client: client,
      config: const AppUpdateConfig(origin: 'https://updates.example.com'),
      platform: AppUpdatePlatform.android,
      versionLoader: () async => '2.4.1',
      downloadDirectoryLoader: () async => Directory('${temp.path}/updates'),
      baseApkLoader: () async => base,
      downloadIdleTimeout: idle,
    );
  }

  Future<File> download() async {
    final check = await service.checkForUpdate();
    expect(check.status, AppUpdateCheckStatus.updateAvailable);
    return service.download(check.candidate!, onProgress: progress.add);
  }

  test('精确基线下载补丁并真实合成，仅完整目标哈希通过才返回APK', () async {
    final result = await download();
    expect(await result.readAsBytes(), target);
    expect(await base.readAsBytes(), original);
    expect(requests.where((r) => r.endsWith('.apk')), isEmpty);
    expect(requests.where((r) => r.endsWith('.patch')), hasLength(1));
    expect(progress.any((p) => p.isDelta), isTrue);
    expect(progress.any((p) => p.phase == AppUpdatePhase.applying), isTrue);
    expect(progress.any((p) => p.phase == AppUpdatePhase.verifying), isTrue);
    expect(
      await Directory('${temp.path}/updates')
          .list()
          .map((e) => e.path)
          .toList(),
      [result.path],
    );
  });

  test('版本号相同但APK字节不同，跳过补丁直接全量', () async {
    await base.writeAsBytes(List.filled(original.length, 70));
    final result = await download();
    expect(await result.readAsBytes(), target);
    expect(requests.where((r) => r.endsWith('.patch')), isEmpty);
    expect(requests.where((r) => r.endsWith('.apk')), hasLength(1));
  });

  test('分包或本机旧APK不可用，自动全量', () async {
    baseUnavailable = true;
    expect(await (await download()).readAsBytes(), target);
    expect(requests.where((r) => r.endsWith('.patch')), isEmpty);
  });

  test('补丁404回退全量一次', () async {
    patchStatus = 404;
    expect(await (await download()).readAsBytes(), target);
    expect(requests.where((r) => r.endsWith('.patch')), hasLength(1));
    expect(requests.where((r) => r.endsWith('.apk')), hasLength(1));
  });

  test('补丁下载哈希不一致，回退全量', () async {
    patch = [...patch]..[0] ^= 1;
    expect(await (await download()).readAsBytes(), target);
    expect(requests.where((r) => r.endsWith('.apk')), hasLength(1));
  });

  test('补丁文件哈希正确但格式损坏，回退全量并清理合成文件', () async {
    patch = [...patch]..[0] ^= 1;
    delta()['sha256'] = sha256.convert(patch).toString();
    final result = await download();
    expect(await result.readAsBytes(), target);
    expect(requests.where((r) => r.endsWith('.apk')), hasLength(1));
    expect(
      await Directory('${temp.path}/updates')
          .list()
          .map((e) => e.path)
          .toList(),
      [result.path],
    );
  });

  test('合成结果大小相同但最终APK哈希不符，必须回退完整包', () async {
    final oldHash = asset()['sha256'];
    target[target.length - 1] = 69;
    asset()['sha256'] = sha256.convert(target).toString();
    expect(asset()['sha256'], isNot(oldHash));
    final result = await download();
    expect(await result.readAsBytes(), target);
    expect(requests.where((r) => r.endsWith('.apk')), hasLength(1));
  });

  for (final invalid in [
    ('format', 'future-format'),
    ('fromVersion', '2.4.0'),
    ('fromSha256', 'bad'),
    ('fromSize', -1),
    ('path', 'releases/2.4.2/../bad.patch'),
    ('path', 'releases/2.4.0/update.patch'),
    ('name', '../bad.patch'),
    ('size', 2 * 1024 * 1024),
  ]) {
    test('可选delta非法或不适配时保留全量能力 $invalid', () async {
      delta()[invalid.$1] = invalid.$2;
      final check = await service.checkForUpdate();
      expect(check.status, AppUpdateCheckStatus.updateAvailable);
      expect(check.candidate!.delta, isNull);
      final result = await service.download(check.candidate!);
      expect(await result.readAsBytes(), target);
      expect(baseLoads, 0);
      expect(requests.where((r) => r.endsWith('.patch')), isEmpty);
    });
  }

  test('旧版全量清单无delta，原链路保持可用', () async {
    asset().remove('delta');
    expect(await (await download()).readAsBytes(), target);
    expect(baseLoads, 0);
  });

  test('已缓存完整目标APK时不再合成或下载', () async {
    final first = await download();
    requests.clear();
    baseLoads = 0;
    final second = await download();
    expect(second.path, first.path);
    expect(requests, ['/downloads/plai/latest.json']);
    expect(baseLoads, 0);
  });

  for (final acceptsRange in [true, false]) {
    test('全量回退保留断点续传，服务器支持Range=$acceptsRange', () async {
      asset().remove('delta');
      final candidate = (await service.checkForUpdate()).candidate!;
      final dir = Directory('${temp.path}/updates');
      await dir.create();
      await File('${dir.path}/2.4.2-${asset()['sha256']}.part')
          .writeAsBytes(target.sublist(0, 1234));
      final ranges = <String?>[];
      useClient(
        MockClient((request) async {
          ranges.add(request.headers['range']);
          if (acceptsRange && ranges.length == 1) {
            return http.Response.bytes(
              target.sublist(1234),
              206,
              headers: {
                'content-range':
                    'bytes 1234-${target.length - 1}/${target.length}',
              },
            );
          }
          return http.Response.bytes(target, 200);
        }),
      );
      final result = await service.download(candidate);
      expect(await result.readAsBytes(), target);
      expect(ranges, acceptsRange ? ['bytes=1234-'] : ['bytes=1234-', null]);
    });
  }

  test('补丁下载停滞自动转全量，并清理补丁半包', () async {
    final candidate = (await service.checkForUpdate()).candidate!;
    final stalled = StreamController<List<int>>();
    stalled.add(patch.sublist(0, 32));
    addTearDown(stalled.close);
    useClient(
      MockClient.streaming((request, _) async {
        requests.add(request.url.path);
        return request.url.path.endsWith('.patch')
            ? http.StreamedResponse(stalled.stream, 200)
            : http.StreamedResponse(Stream.value(target), 200);
      }),
      idle: const Duration(milliseconds: 50),
    );
    final result = await service.download(candidate, onProgress: progress.add);
    expect(await result.readAsBytes(), target);
    expect(progress.any((p) => p.phase == AppUpdatePhase.fullFallback), isTrue);
    expect(requests.where((r) => r.endsWith('.apk')), hasLength(1));
    expect(
      await Directory('${temp.path}/updates')
          .list()
          .map((e) => e.path)
          .toList(),
      [result.path],
    );
  });

  test('崩溃后留下完整part时先校验复用，不再请求bytes=size-导致416', () async {
    final dir = Directory('${temp.path}/updates');
    await dir.create();
    await File('${dir.path}/2.4.2-${asset()['sha256']}.part')
        .writeAsBytes(target);
    final result = await download();
    expect(await result.readAsBytes(), target);
    expect(requests, ['/downloads/plai/latest.json']);
    expect(baseLoads, 0);
  });

  test('完整part长度正确但哈希错误时清理后从头下载', () async {
    asset().remove('delta');
    final candidate = (await service.checkForUpdate()).candidate!;
    final dir = Directory('${temp.path}/updates');
    await dir.create();
    await File('${dir.path}/2.4.2-${asset()['sha256']}.part')
        .writeAsBytes(List.filled(target.length, 90));
    useClient(
      MockClient((request) async {
        expect(request.headers['range'], isNull);
        return http.Response.bytes(target, 200);
      }),
    );
    expect(await (await service.download(candidate)).readAsBytes(), target);
  });

  test('补丁与全量都失败时停止，不返回未经验证的安装包', () async {
    final candidate = (await service.checkForUpdate()).candidate!;
    useClient(
      MockClient((request) async {
        requests.add(request.url.path);
        return http.Response('failed', 503);
      }),
    );
    await expectLater(
      service.download(candidate),
      throwsA(isA<AppUpdateException>()),
    );
    expect(requests.where((r) => r.endsWith('.patch')), hasLength(1));
    expect(requests.where((r) => r.endsWith('.apk')), hasLength(1));
    expect(await Directory('${temp.path}/updates').list().toList(), isEmpty);
  });
}
