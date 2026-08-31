import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/settings/settings_providers.dart';

/// 主题相关设置键。
abstract final class ThemeSettingsKeys {
  /// 主题模式设置键：`'system'` / `'light'` / `'dark'`，缺省视为跟随系统。
  static const String themeMode = 'theme_mode';
}

/// 主题模式控制器：跟随系统 / 浅色 / 深色，持久化到设置表。
///
/// 应用根 `PlaiApp` 通过 `ref.watch(themeModeProvider)` 读取本控制器，
/// 切换后实时生效（`MaterialApp.themeMode` 随 state 更新）。
class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    _restore();
    return ThemeMode.system;
  }

  /// 从设置表恢复已保存的主题模式；失败时回退「跟随系统」。
  Future<void> _restore() async {
    ThemeMode restored = ThemeMode.system;
    try {
      final String? value = await ref
          .read(settingsRepositoryProvider)
          .getValue(ThemeSettingsKeys.themeMode);
      restored = _fromStorage(value);
    } catch (_) {
      // 数据库不可用（如 widget 测试环境 / 首启异常）时保持默认。
    }
    if (restored != state) state = restored;
  }

  /// 切换主题模式并持久化；设置成功后实时生效。
  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    try {
      await ref
          .read(settingsRepositoryProvider)
          .setValue(ThemeSettingsKeys.themeMode, _toStorage(mode));
    } catch (_) {
      // 持久化失败不阻断本次会话内的主题切换。
    }
  }

  static ThemeMode _fromStorage(String? value) {
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static String _toStorage(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }
}

/// 主题模式 Provider（`PlaiApp.themeMode` 读取它）。
final themeModeProvider =
    NotifierProvider<ThemeModeController, ThemeMode>(ThemeModeController.new);
