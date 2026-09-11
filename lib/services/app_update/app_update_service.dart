import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Plai 唯一受信的更新源。发行构建可用 dart-define 指向专用 staging 域名，
/// 但运行时不会接受服务端给出的任意下载 URL。
class AppUpdateConfig {
  const AppUpdateConfig({
    this.origin = const String.fromEnvironment(
      'PLAI_UPDATE_ORIGIN',
      defaultValue: 'https://liuyangyang.me',
    ),
    this.manifestPath = '/downloads/plai/latest.json',
    this.downloadPrefix = '/downloads/plai/',
  });

  final String origin;
  final String manifestPath;
  final String downloadPrefix;

  Uri get originUri {
    final Uri value = Uri.parse(origin);
    if (value.scheme != 'https' || value.host.isEmpty || value.hasQuery) {
      throw const AppUpdateException('更新源必须是固定的 HTTPS Origin。');
    }
    return value;
  }

  Uri get manifestUri => originUri.replace(path: manifestPath);

  Uri urlForPath(String path) {
    if (!_isSafeRelativePath(path) || !path.startsWith('releases/')) {
      throw const AppUpdateException('更新文件路径不安全。');
    }
    final Uri uri = originUri.replace(path: '$downloadPrefix$path');
    if (uri.scheme != 'https' ||
        uri.host != originUri.host ||
        uri.port != originUri.port) {
      throw const AppUpdateException('更新文件不属于受信更新源。');
    }
    return uri;
  }
}

enum AppUpdatePlatform {
  android,
  ios,
  unsupported;

  static AppUpdatePlatform current() {
    if (Platform.isAndroid) return AppUpdatePlatform.android;
    if (Platform.isIOS) return AppUpdatePlatform.ios;
    return AppUpdatePlatform.unsupported;
  }

  String get manifestKey => switch (this) {
    AppUpdatePlatform.android => 'android',
    AppUpdatePlatform.ios => 'ios',
    AppUpdatePlatform.unsupported => '',
  };
}

class AppUpdateCandidate {
  const AppUpdateCandidate({
    required this.currentVersion,
    required this.version,
    required this.notes,
    required this.announcement,
    required this.platform,
    this.asset,
    this.storeUrl,
  });

  final String currentVersion;
  final String version;
  final String notes;
  final String announcement;
  final AppUpdatePlatform platform;
  final AppUpdateAsset? asset;
  final Uri? storeUrl;

  bool get requiresStore => storeUrl != null;
}

class AppUpdateAsset {
  const AppUpdateAsset({
    required this.name,
    required this.path,
    required this.size,
    required this.sha256,
  });

  final String name;
  final String path;
  final int size;
  final String sha256;
}

class AppUpdateProgress {
  const AppUpdateProgress(this.downloadedBytes, this.totalBytes);

  final int downloadedBytes;
  final int totalBytes;

  double get fraction => totalBytes == 0 ? 0 : downloadedBytes / totalBytes;
}

class AppUpdateException implements Exception {
  const AppUpdateException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 原生更新清单的读取、严格校验和带 Range 续传的完整包下载。
class AppUpdateService {
  AppUpdateService({
    http.Client? client,
    this.config = const AppUpdateConfig(),
    Future<String> Function()? versionLoader,
    AppUpdatePlatform? platform,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _versionLoader = versionLoader ?? _platformVersion,
       _platform = platform ?? AppUpdatePlatform.current();

  static const int _maxArtifactBytes = 2 * 1024 * 1024 * 1024;
  static const int _maxManifestBytes = 256 * 1024;

  final http.Client _client;
  final bool _ownsClient;
  final AppUpdateConfig config;
  final Future<String> Function() _versionLoader;
  final AppUpdatePlatform _platform;

  static Future<String> _platformVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  Future<String> currentVersion() => _versionLoader();

  Future<AppUpdateCandidate?> checkForUpdate() async {
    if (_platform == AppUpdatePlatform.unsupported) return null;
    try {
      final String current = await currentVersion();
      final Map<String, Object?> manifest = await _readManifest();
      final String latest = _requiredVersion(manifest['version']);
      if (_compareSemver(latest, current) <= 0) return null;

      final String notes = _optionalText(manifest['notes']);
      final String announcement = _optionalText(manifest['announcement']);
      final Map<String, Object?> assets = _object(manifest['assets'], 'assets');
      final Map<String, Object?> platformAsset = _object(
        assets[_platform.manifestKey],
        _platform.manifestKey,
      );

      if (_platform == AppUpdatePlatform.ios) {
        final Uri storeUrl = _trustedStoreUrl(platformAsset['storeUrl']);
        return AppUpdateCandidate(
          currentVersion: current,
          version: latest,
          notes: notes,
          announcement: announcement,
          platform: _platform,
          storeUrl: storeUrl,
        );
      }

      return AppUpdateCandidate(
        currentVersion: current,
        version: latest,
        notes: notes,
        announcement: announcement,
        platform: _platform,
        asset: _parseAsset(platformAsset),
      );
    } catch (_) {
      // 自动检查绝不影响首屏；手工诊断可通过服务端日志与发布前校验完成。
      return null;
    }
  }

  Future<File> download(
    AppUpdateCandidate candidate, {
    void Function(AppUpdateProgress progress)? onProgress,
  }) async {
    final AppUpdateAsset asset =
        candidate.asset ?? (throw const AppUpdateException('当前平台没有可下载的更新包。'));
    final Uri url = config.urlForPath(asset.path);
    final Directory support = await getApplicationSupportDirectory();
    final Directory directory = Directory(
      p.join(support.path, 'updates', 'partials'),
    );
    await directory.create(recursive: true);
    final String stem = '${candidate.version}-${asset.sha256}';
    final File partial = File(p.join(directory.path, '$stem.part'));
    final File completed = File(p.join(directory.path, asset.name));

    if (await completed.exists()) {
      if (await _hasExpectedDigest(completed, asset.sha256, asset.size)) {
        return completed;
      }
      await completed.delete();
    }

    int offset = await partial.exists() ? await partial.length() : 0;
    if (offset > asset.size) {
      await partial.delete();
      offset = 0;
    }
    bool restarted = false;
    while (true) {
      final http.Request request = http.Request('GET', url)
        ..followRedirects = false
        ..headers['Accept'] = 'application/octet-stream';
      if (offset > 0) request.headers['Range'] = 'bytes=$offset-';
      final http.StreamedResponse response = await _client.send(request);
      if (response.isRedirect) {
        throw const AppUpdateException('更新下载发生了不受信任的跳转。');
      }
      if (offset > 0 && response.statusCode == HttpStatus.ok && !restarted) {
        await partial.delete();
        offset = 0;
        restarted = true;
        continue;
      }
      if (offset > 0) {
        if (response.statusCode != HttpStatus.partialContent ||
            !_resumesAt(
              response.headers['content-range'],
              offset,
              asset.size,
            )) {
          throw const AppUpdateException('更新服务器未正确支持断点续传。');
        }
      } else if (response.statusCode != HttpStatus.ok) {
        throw AppUpdateException('下载更新失败（HTTP ${response.statusCode}）。');
      }

      int downloaded = offset;
      final IOSink sink = partial.openWrite(
        mode: offset == 0 ? FileMode.write : FileMode.append,
      );
      try {
        await for (final List<int> chunk in response.stream) {
          downloaded += chunk.length;
          if (downloaded > asset.size || downloaded > _maxArtifactBytes) {
            throw const AppUpdateException('更新文件大小异常。');
          }
          sink.add(chunk);
          onProgress?.call(AppUpdateProgress(downloaded, asset.size));
        }
      } finally {
        await sink.close();
      }
      if (downloaded != asset.size ||
          !await _hasExpectedDigest(partial, asset.sha256, asset.size)) {
        if (await partial.exists()) await partial.delete();
        throw const AppUpdateException('更新文件校验失败，已删除不可信文件。');
      }
      if (await completed.exists()) await completed.delete();
      return partial.rename(completed.path);
    }
  }

  Future<Map<String, Object?>> _readManifest() async {
    final http.Request request = http.Request('GET', config.manifestUri)
      ..followRedirects = false
      ..headers['Accept'] = 'application/json';
    final http.StreamedResponse response = await _client.send(request);
    if (response.isRedirect || response.statusCode != HttpStatus.ok) {
      throw const AppUpdateException('更新清单不可用。');
    }
    final List<int> bytes = await response.stream.fold<List<int>>(<int>[], (
      List<int> all,
      List<int> next,
    ) {
      if (all.length + next.length > _maxManifestBytes) {
        throw const AppUpdateException('更新清单过大。');
      }
      return all..addAll(next);
    });
    return _object(jsonDecode(utf8.decode(bytes)), 'manifest');
  }

  AppUpdateAsset _parseAsset(Map<String, Object?> value) {
    final String name = value['name'] as String? ?? '';
    final String path = value['path'] as String? ?? '';
    final int? size = value['size'] as int?;
    final String sha = value['sha256'] as String? ?? '';
    if (!_safeName.hasMatch(name) ||
        !_isSafeRelativePath(path) ||
        size == null ||
        size < 1 ||
        size > _maxArtifactBytes ||
        !RegExp(r'^[A-Fa-f0-9]{64}$').hasMatch(sha)) {
      throw const AppUpdateException('更新文件清单不合法。');
    }
    config.urlForPath(path); // 再做固定源与前缀校验。
    return AppUpdateAsset(
      name: name,
      path: path,
      size: size,
      sha256: sha.toLowerCase(),
    );
  }

  Uri _trustedStoreUrl(Object? raw) {
    if (raw is! String) throw const AppUpdateException('App Store 地址缺失。');
    final Uri url =
        Uri.tryParse(raw) ??
        (throw const AppUpdateException('App Store 地址不合法。'));
    if (url.scheme != 'https' || url.host != 'apps.apple.com') {
      throw const AppUpdateException('App Store 地址不受信任。');
    }
    return url;
  }

  Future<bool> _hasExpectedDigest(File file, String expected, int size) async {
    if (!await file.exists() || await file.length() != size) return false;
    final Digest digest = await sha256.bind(file.openRead()).single;
    return digest.toString().toLowerCase() == expected.toLowerCase();
  }

  bool _resumesAt(String? range, int offset, int total) {
    final RegExpMatch? match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
        .firstMatch(range ?? '');
    return match != null &&
        int.parse(match.group(1)!) == offset &&
        int.parse(match.group(3)!) == total;
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}

final RegExp _safeName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$');

bool _isSafeRelativePath(String value) {
  if (value.isEmpty ||
      value.startsWith('/') ||
      value.contains('\\') ||
      value.contains('?') ||
      value.contains('#')) {
    return false;
  }
  return value
      .split('/')
      .every(
        (String segment) =>
            segment.isNotEmpty && segment != '.' && segment != '..',
      );
}

Map<String, Object?> _object(Object? value, String field) {
  if (value is! Map) throw AppUpdateException('$field 必须是对象。');
  return value.map<String, Object?>((Object? key, Object? item) {
    if (key is! String) throw AppUpdateException('$field 含非法字段。');
    return MapEntry<String, Object?>(key, item);
  });
}

String _requiredVersion(Object? raw) {
  if (raw is! String || !_semver.hasMatch(raw)) {
    throw const AppUpdateException('更新版本号不合法。');
  }
  return raw;
}

String _optionalText(Object? raw) {
  if (raw == null) return '';
  if (raw is! String || raw.length > 12000) {
    throw const AppUpdateException('更新说明不合法。');
  }
  return raw;
}

final RegExp _semver = RegExp(
  r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
);

int _compareSemver(String left, String right) {
  final RegExpMatch a = _semver.firstMatch(left)!;
  final RegExpMatch b = _semver.firstMatch(right)!;
  for (int i = 1; i <= 3; i++) {
    final int comparison = int.parse(a.group(i)!)
        .compareTo(int.parse(b.group(i)!));
    if (comparison != 0) return comparison;
  }
  final String? aPre = a.group(4);
  final String? bPre = b.group(4);
  if (aPre == null && bPre == null) return 0;
  if (aPre == null) return 1;
  if (bPre == null) return -1;
  final List<String> aParts = aPre.split('.');
  final List<String> bParts = bPre.split('.');
  for (int i = 0; i < aParts.length || i < bParts.length; i++) {
    if (i == aParts.length) return -1;
    if (i == bParts.length) return 1;
    final bool aNumber = RegExp(r'^\d+$').hasMatch(aParts[i]);
    final bool bNumber = RegExp(r'^\d+$').hasMatch(bParts[i]);
    final int comparison = aNumber && bNumber
        ? int.parse(aParts[i]).compareTo(int.parse(bParts[i]))
        : aNumber
        ? -1
        : bNumber
        ? 1
        : aParts[i].compareTo(bParts[i]);
    if (comparison != 0) return comparison;
  }
  return 0;
}
