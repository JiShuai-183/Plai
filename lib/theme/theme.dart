import 'package:flutter/material.dart';

import 'colors.dart';

/// Plai 全局主题（Material 3，绿色系）。
///
/// 在 [main.dart] 中通过 `themeMode: ThemeMode.system` 跟随系统深色切换，
/// 亮/暗主题分别对应 [light] 与 [dark]。
abstract final class PlaiTheme {
  // ColorScheme.fromSeed 需在 HCT 色彩空间推算整套配色，开销不小；而主题
  // 只由亮度决定、与运行时状态无关，故按亮度缓存后复用（根节点重建 /
  // themeMode 变化时不再重复计算）。
  static ThemeData? _light;
  static ThemeData? _dark;

  /// 亮色主题（首次构建后缓存复用）。
  static ThemeData light() => _light ??= _build(Brightness.light);

  /// 暗色主题（首次构建后缓存复用）。
  static ThemeData dark() => _dark ??= _build(Brightness.dark);

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
