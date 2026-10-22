import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_update_service.dart';

class AppUpdateCompletion {
  const AppUpdateCompletion({
    required this.version,
    required this.notes,
    required this.announcement,
  });

  final String version;
  final String notes;
  final String announcement;
}

/// 更新交接记录保存在应用私有偏好中：安装覆盖后数据仍在，新版本只消费一次。
/// 没有应用内交接记录时，判断要不要用线上清单补一次「已更新至 X」公告。
///
/// - [lastSeenVersion] 是本机上次记录到的版本：与当前相同 → 本版本已处理过，不弹；
/// - 有历史记录且不同 → 明确是升级，弹；
/// - 没有任何历史记录（≤2.3.4 的老版本不写这个键）→ 只有本次确实是覆盖安装才弹，
///   避免全新安装的用户也被弹一条「已更新至当前版本」。
bool shouldAnnounceAfterUpgrade({
  required String currentVersion,
  String? lastSeenVersion,
  required bool upgraded,
}) {
  if (lastSeenVersion == currentVersion) return false;
  if (lastSeenVersion != null) return true;
  return upgraded;
}

class AppUpdateCompletionStore {
  static const String _key = 'app.update.pending_completion.v1';
  static const String _lastSeenKey = 'app.update.last_seen_version.v1';

  Future<void> markPending(AppUpdateCandidate update) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _key,
      jsonEncode(<String, String>{
        'version': update.version,
        'notes': update.notes,
        'announcement': update.announcement,
      }),
    );
  }

  /// 本机上次「已处理过公告」的版本号（没有则 null）。
  Future<String?> lastSeenVersion() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    return preferences.getString(_lastSeenKey);
  }

  /// 记录本机已处理过的版本，保证同一版本只公告一次。
  Future<void> recordSeenVersion(String version) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.setString(_lastSeenKey, version);
  }

  Future<AppUpdateCompletion?> consumeForVersion(String currentVersion) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String? encoded = preferences.getString(_key);
    if (encoded == null) return null;
    try {
      final Object? decoded = jsonDecode(encoded);
      if (decoded is! Map || decoded['version'] != currentVersion) return null;
      final String notes = decoded['notes'] is String
          ? decoded['notes'] as String
          : '';
      final String announcement = decoded['announcement'] is String
          ? decoded['announcement'] as String
          : '';
      await preferences.remove(_key);
      return AppUpdateCompletion(
        version: currentVersion,
        notes: notes,
        announcement: announcement,
      );
    } catch (_) {
      await preferences.remove(_key);
      return null;
    }
  }
}
