import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/settings/settings_providers.dart';

/// 主题相关设置键。
abstract final class ThemeSettingsKeys {
  /// 主题模式设置键：`'system'` / `'light'` / `'white'` / `'dark'`，
  /// 缺省（含旧版本写入的未知值）视为跟随系统。
  static const String themeMode = 'theme_mode';
}

/// 主题模式。
///
/// Flutter 的 [ThemeMode] 只有 跟随系统/浅色/深色 三档，本 App 多一档
/// 「白色」（纯白底 + 中性灰辅助），故自定义一套。枚举 [name] 即持久化串，
/// 与旧版本的 `'system'`/`'light'`/`'dark'` 天然兼容。
enum PlaiThemeMode {
  /// 跟随系统：系统亮色侧用 [white]，暗色侧用深色（见 `main.dart` 装配）。
  system('跟随系统'),

  /// 浅色：绿色品牌。
  light('浅色'),

  /// 白色：纯白底 + 中性灰辅助。
  white('白色'),

  /// 深色：中性灰阶。
  dark('深色');

  const PlaiThemeMode(this.label);

  /// 设置页展示用的中文名。
  final String label;

  /// 从持久化串还原；未知/缺失回退 [system]。
  static PlaiThemeMode fromStorage(String? value) {
    for (final PlaiThemeMode mode in PlaiThemeMode.values) {
      if (mode.name == value) return mode;
    }
    return PlaiThemeMode.system;
  }
}

/// 主题模式控制器：持久化到设置表（键 `theme_mode`）。
///
/// 应用根 `PlaiApp` 通过 `ref.watch(themeModeProvider)` 读取本控制器，
/// 据此选择亮色侧主题并映射到 `MaterialApp.themeMode`。
class ThemeModeController extends Notifier<PlaiThemeMode> {
  @override
  PlaiThemeMode build() {
    _restore();
    return PlaiThemeMode.system;
  }

  /// 从设置表恢复已保存的主题模式；失败时回退「跟随系统」。
  Future<void> _restore() async {
    PlaiThemeMode restored = PlaiThemeMode.system;
    try {
      final String? value = await ref
          .read(settingsRepositoryProvider)
          .getValue(ThemeSettingsKeys.themeMode);
      restored = PlaiThemeMode.fromStorage(value);
    } catch (_) {
      // 数据库不可用（如 widget 测试环境 / 首启异常）时保持默认。
    }
    if (restored != state) state = restored;
  }

  /// 切换主题模式并持久化；设置成功后实时生效。
  Future<void> setThemeMode(PlaiThemeMode mode) async {
    state = mode;
    try {
      await ref
          .read(settingsRepositoryProvider)
          .setValue(ThemeSettingsKeys.themeMode, mode.name);
    } catch (_) {
      // 持久化失败不阻断本次会话内的主题切换。
    }
  }
}

/// 主题模式 Provider（`PlaiApp` 读取它装配主题）。
final themeModeProvider =
    NotifierProvider<ThemeModeController, PlaiThemeMode>(ThemeModeController.new);
