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
class AppUpdateCompletionStore {
  static const String _key = 'app.update.pending_completion.v1';

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
