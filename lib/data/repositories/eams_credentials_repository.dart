import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 仅供教务登录使用的本机凭据；不提供日志输出或备份序列化接口。
class EamsCredentials {
  const EamsCredentials({required this.username, required this.password});

  final String username;
  final String password;
}

abstract interface class IEamsCredentialsRepository {
  Future<EamsCredentials?> read();
  Future<void> save(EamsCredentials credentials);
  Future<void> clear();
}

/// 独立于 SQLite / .plai 备份。不得降级到明文存储。
///
/// Android 使用 Keystore 保护的加密存储，并在两套系统备份规则中排除。
/// iOS 限本机解锁时读取，关闭 iCloud 同步和跨设备迁移。
class EamsCredentialsRepository implements IEamsCredentialsRepository {
  EamsCredentialsRepository({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              storageNamespace: 'plai_eams_credentials',
              resetOnError: false,
            ),
            iOptions: IOSOptions(
              accountName: 'plai.eams.credentials',
              accessibility: KeychainAccessibility.unlocked_this_device,
              synchronizable: false,
            ),
          );

  static const String storageKey = 'eams.credentials.v1';
  final FlutterSecureStorage _storage;

  @override
  Future<EamsCredentials?> read() async {
    final String? value = await _storage.read(key: storageKey);
    if (value == null) return null;
    // 不把原始值放进 FormatException（可能含密码）。损坏时显式报错，
    // 留给用户「清除已保存的账号密码」，不悄悄覆盖或假装没有保存。
    try {
      final dynamic decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic> &&
          decoded['username'] is String &&
          decoded['password'] is String) {
        final String username = decoded['username'] as String;
        final String password = decoded['password'] as String;
        if (username.trim().isNotEmpty && password.isNotEmpty) {
          return EamsCredentials(username: username, password: password);
        }
      }
    } catch (_) {
      // 下方抛无敏感内容的固定错误。
    }
    throw const FormatException('本机教务凭据损坏');
  }

  @override
  Future<void> save(EamsCredentials credentials) async {
    final String username = credentials.username.trim();
    if (username.isEmpty || credentials.password.isEmpty) {
      throw ArgumentError('学号与密码不能为空');
    }
    // 一条加密记录，避免两个键分开写导致账号与密码错配。密码保留原样。
    await _storage.write(
      key: storageKey,
      value: jsonEncode(<String, String>{
        'username': username,
        'password': credentials.password,
      }),
    );
  }

  @override
  Future<void> clear() => _storage.delete(key: storageKey);
}
