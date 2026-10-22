import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 一个受信更新源：固定 HTTPS Origin + 可选的固定连接地址。
///
/// [resolvedIp] 服务于「域名尚未备案 / 无法解析，但服务器 IP 已就绪」的过渡期：
/// 只有 TCP 的连接目标被改成该 IP，TLS 的 SNI 与证书主机名校验仍然针对 Origin
/// 的域名。因此 HTTPS 强制、证书校验、路径前缀校验全部保持有效，不会退化成
/// 跳过证书校验或退回明文 HTTP。
class AppUpdateOrigin {
  const AppUpdateOrigin(this.base, {this.resolvedIp});

  final String base;
  final String? resolvedIp;

  Uri get uri {
    final Uri value = Uri.parse(base);
    if (value.scheme != 'https' || value.host.isEmpty || value.hasQuery) {
      throw const AppUpdateException('更新源必须是固定的 HTTPS Origin。');
    }
    return value;
  }

  @override
  String toString() => resolvedIp == null ? base : '$base (连接 $resolvedIp)';

  @override
  bool operator ==(Object other) =>
      other is AppUpdateOrigin &&
      other.base == base &&
      other.resolvedIp == resolvedIp;

  @override
  int get hashCode => Object.hash(base, resolvedIp);
}

/// Plai 受信更新源的配置。发行构建可用 dart-define 指向专用 staging 域名，
/// 但运行时不会接受服务端给出的任意下载 URL。
///
/// 2.2.8 起主源指向新服务器（liuyangyang.online，连接固定解析到
/// 43.142.93.106），旧域名作为只读回退源保留：两处发布的必须是同一份字节，
/// 新源不可达时仍能取到同一清单，不会因为单一源故障打断整个更新通道。
class AppUpdateConfig {
  const AppUpdateConfig({
    this.origin = const String.fromEnvironment(
      'PLAI_UPDATE_ORIGIN',
      defaultValue: 'https://liuyangyang.online',
    ),
    this.hostOverrides = const <String, String>{
      'liuyangyang.online': '43.142.93.106',
    },
    this.fallbackOrigins = const <String>['https://liuyangyang.me'],
    this.manifestPath = '/downloads/plai/latest.json',
    this.downloadPrefix = '/downloads/plai/',
  });

  final String origin;

  /// 域名 -> 固定连接 IP。只影响 TCP 连接目标，不影响 TLS 主机名校验。
  final Map<String, String> hostOverrides;

  /// 主源不可达时按顺序尝试的回退源（同样是固定 HTTPS Origin）。
  final List<String> fallbackOrigins;

  final String manifestPath;
  final String downloadPrefix;

  AppUpdateOrigin get primaryOrigin => _originFor(origin);

  /// 全部受信源，按优先级排列（主源在前）。
  List<AppUpdateOrigin> get origins => <AppUpdateOrigin>[
    primaryOrigin,
    for (final String base in fallbackOrigins)
      if (base.trim().isNotEmpty) _originFor(base.trim()),
  ];

  AppUpdateOrigin _originFor(String base) =>
      AppUpdateOrigin(base, resolvedIp: hostOverrides[Uri.parse(base).host]);

  Uri get originUri => primaryOrigin.uri;
  Uri get manifestUri => manifestUriFor(primaryOrigin);

  Uri manifestUriFor(AppUpdateOrigin origin) =>
      origin.uri.replace(path: manifestPath);

  Uri urlForPath(String path, {AppUpdateOrigin? origin}) {
    final Uri base = (origin ?? primaryOrigin).uri;
    if (!_isSafeRelativePath(path) || !path.startsWith('releases/')) {
      throw const AppUpdateException('更新文件路径不安全。');
    }
    final Uri uri = base.replace(path: '$downloadPrefix$path');
    if (uri.scheme != 'https' ||
        uri.host != base.host ||
        uri.port != base.port) {
      throw const AppUpdateException('更新文件不属于受信更新源。');
    }
    return uri;
  }
}

/// 构造更新专用 HTTP 客户端。
///
/// 与普通 http.Client() 的唯一差别：对 [hostOverrides] 里登记过的域名，TCP
/// 连接直接打到固定 IP；TLS 握手、SNI、证书主机名校验与 HTTP 头仍按域名正常
/// 处理（由 HttpClient 在拿到 socket 后自行完成）。
http.Client createUpdateHttpClient(Map<String, String> hostOverrides) {
  final HttpClient inner = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);
  if (hostOverrides.isNotEmpty) {
    inner.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) {
      final String? pinned = hostOverrides[uri.host];
      final bool secure = uri.scheme == 'https';
      // 自定义 connectionFactory 时 HttpClient **不再**替我们做 TLS 包装，
      // 必须自己返回已经完成握手的 SecureSocket（见 dart:io http_impl 的
      // _ConnectionTarget.connect）。否则 https 会以明文写进 443 端口。
      if (pinned == null) {
        return secure
            ? SecureSocket.startConnect(uri.host, uri.port)
            : Socket.startConnect(uri.host, uri.port);
      }
      final Future<Socket> raw = Socket.startConnect(pinned, uri.port).then(
        (ConnectionTask<Socket> task) => task.socket,
      );
      // 连接目标是固定 IP，但 host 仍传域名：SNI 与证书主机名校验都按域名走。
      final Future<Socket> socket = secure
          ? raw.then(
              (Socket socket) =>
                  SecureSocket.secure(socket, host: uri.host),
            )
          : raw;
      return Future<ConnectionTask<Socket>>.value(
        ConnectionTask.fromSocket(socket, () {}),
      );
    };
  }
  return IOClient(inner);
}

/// 一次清单读取的结果：内容 + 实际命中的源（下载必须回到同一个源）。
class _ManifestSnapshot {
  const _ManifestSnapshot({required this.manifest, required this.origin});
  final Map<String, Object?> manifest;
  final AppUpdateOrigin origin;
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
    this.downloadOrigin,
  });

  final String currentVersion;
  final String version;
  final String notes;
  final String announcement;
  final AppUpdatePlatform platform;
  final AppUpdateAsset? asset;
  final Uri? storeUrl;

  /// 命中该清单的受信源。下载必须回到同一个源，避免清单与产物跨源混用。
  final AppUpdateOrigin? downloadOrigin;

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

enum AppUpdateCheckStatus { upToDate, updateAvailable, failed, unsupported }

/// 检查更新的**三态结果**。
///
/// 历史实现把 checkForUpdate 里的一切异常都 catch 成 null，调用方于是把
/// 「联网失败 / 清单非法 / 证书异常 / 版本读取失败」统统显示成「已是最新版本」
/// —— 这正是用户反馈的「无论是否验证到远端新版本都只显示已是最新」的根因。
/// 现在三种结果必须显式区分，失败时要把可读原因带回 UI。
class AppUpdateCheckResult {
  const AppUpdateCheckResult._({
    required this.status,
    this.currentVersion = '',
    this.candidate,
    this.message = '',
  });

  const AppUpdateCheckResult.upToDate(String currentVersion)
      : this._(
          status: AppUpdateCheckStatus.upToDate,
          currentVersion: currentVersion,
        );

  // 不能是 const 重定向构造：candidate.currentVersion 不是常量表达式。
  factory AppUpdateCheckResult.updateAvailable(AppUpdateCandidate candidate) =>
      AppUpdateCheckResult._(
        status: AppUpdateCheckStatus.updateAvailable,
        currentVersion: candidate.currentVersion,
        candidate: candidate,
      );

  const AppUpdateCheckResult.failed(String message)
      : this._(status: AppUpdateCheckStatus.failed, message: message);

  const AppUpdateCheckResult.unsupported()
      : this._(
          status: AppUpdateCheckStatus.unsupported,
          message: '当前平台不支持应用内更新。',
        );

  final AppUpdateCheckStatus status;
  final String currentVersion;
  final AppUpdateCandidate? candidate;

  /// 失败原因（用户可读）；仅在 status == failed 时有意义。
  final String message;

  bool get hasUpdate => status == AppUpdateCheckStatus.updateAvailable;
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
    AppUpdateConfig? config,
    Future<String> Function()? versionLoader,
    AppUpdatePlatform? platform,
  }) : config = config ?? const AppUpdateConfig(),
       _client = client ??
           createUpdateHttpClient(
             (config ?? const AppUpdateConfig()).hostOverrides,
           ),
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

  /// 检查远端是否发布了更高版本。
  ///
  /// 三态返回：已是最新 / 有新版本 / 失败（带可读原因）。**失败绝不能伪装成
  /// 已是最新** —— 主源不可达时会按 [AppUpdateConfig.fallbackOrigins] 依次重试，
  /// 全部失败才判为失败。
  Future<AppUpdateCheckResult> checkForUpdate() async {
    if (_platform == AppUpdatePlatform.unsupported) {
      return const AppUpdateCheckResult.unsupported();
    }
    final String current;
    try {
      current = await currentVersion();
    } catch (_) {
      return const AppUpdateCheckResult.failed('无法读取当前版本号，请稍后重试。');
    }
    try {
      final _ManifestSnapshot snapshot = await _readManifest();
      final Map<String, Object?> manifest = snapshot.manifest;
      final String latest = _requiredVersion(manifest['version']);
      final String notes = _optionalText(manifest['notes']);
      final String announcement = _optionalText(manifest['announcement']);
      if (_compareSemver(latest, current) <= 0) {
        return AppUpdateCheckResult.upToDate(current);
      }

      final Map<String, Object?> assets = _object(manifest['assets'], 'assets');
      final Map<String, Object?> platformAsset = _object(
        assets[_platform.manifestKey],
        _platform.manifestKey,
      );

      if (_platform == AppUpdatePlatform.ios) {
        final Uri storeUrl = _trustedStoreUrl(platformAsset['storeUrl']);
        return AppUpdateCheckResult.updateAvailable(
          AppUpdateCandidate(
            currentVersion: current,
            version: latest,
            notes: notes,
            announcement: announcement,
            platform: _platform,
            storeUrl: storeUrl,
            downloadOrigin: snapshot.origin,
          ),
        );
      }

      return AppUpdateCheckResult.updateAvailable(
        AppUpdateCandidate(
          currentVersion: current,
          version: latest,
          notes: notes,
          announcement: announcement,
          platform: _platform,
          asset: _parseAsset(platformAsset),
          downloadOrigin: snapshot.origin,
        ),
      );
    } on AppUpdateException catch (error) {
      return AppUpdateCheckResult.failed(error.message);
    } catch (error) {
      return AppUpdateCheckResult.failed(_describeFailure(error));
    }
  }

  Future<File> download(
    AppUpdateCandidate candidate, {
    void Function(AppUpdateProgress progress)? onProgress,
  }) async {
    final AppUpdateAsset asset =
        candidate.asset ?? (throw const AppUpdateException('当前平台没有可下载的更新包。'));
    final Uri url =
        config.urlForPath(asset.path, origin: candidate.downloadOrigin);
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

  /// 按优先级依次尝试全部受信源，返回命中的清单与其来源。
  Future<_ManifestSnapshot> _readManifest() async {
    Object? lastError;
    for (final AppUpdateOrigin origin in config.origins) {
      try {
        return _ManifestSnapshot(
          manifest: await _readManifestFrom(origin),
          origin: origin,
        );
      } catch (error) {
        lastError = error;
      }
    }
    if (lastError is AppUpdateException) throw lastError;
    throw AppUpdateException(_describeFailure(lastError));
  }

  Future<Map<String, Object?>> _readManifestFrom(AppUpdateOrigin origin) async {
    final http.Request request =
        http.Request('GET', config.manifestUriFor(origin))
          ..followRedirects = false
          ..headers['Accept'] = 'application/json';
    final http.StreamedResponse response = await _client.send(request);
    if (response.isRedirect || response.statusCode != HttpStatus.ok) {
      throw AppUpdateException(
        '更新清单不可用（HTTP ${response.statusCode}）。',
      );
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

/// 把底层网络/协议异常翻译成用户能理解的一句话。
String _describeFailure(Object? error) {
  if (error is SocketException) return '无法连接更新服务器，请检查网络后重试。';
  if (error is HandshakeException || error is TlsException) {
    return '与更新服务器的安全连接失败（证书校验未通过）。';
  }
  if (error is TimeoutException) return '更新服务器响应超时，请稍后重试。';
  if (error is HttpException || error is http.ClientException) {
    return '与更新服务器的连接中断，请稍后重试。';
  }
  return '检查更新失败，请稍后重试。';
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
