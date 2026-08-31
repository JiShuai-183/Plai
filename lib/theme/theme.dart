import 'package:flutter/material.dart';

import 'colors.dart';

/// Plai 全局主题（Material 3，绿色系）。
///
/// 在 [main.dart] 中通过 `themeMode: ThemeMode.system` 跟随系统深色切换，
/// 亮/暗主题分别对应 [light] 与 [dark]。
abstract final class PlaiTheme {
  /// 亮色主题。
  static ThemeData light() => _build(Brightness.light);

  /// 暗色主题。
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: PlaiColors.seed,
      brightness: brightness,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant),
    );
  }
}
