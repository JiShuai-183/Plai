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
    // 深色主题走中性灰阶（monochrome）：绿色 seed 派生出的深色方案里，
    // 强调色是浅绿、气泡底是深绿、SnackBar 底是浅灰绿，这些绿调在深色
    // 界面上与整体冲突。改用灰阶后深色下无任何色相偏向（错误色仍为 M3
    // 的红色语义色）；浅色主题保持绿色品牌不变。
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: PlaiColors.seed,
      brightness: brightness,
      dynamicSchemeVariant: brightness == Brightness.dark
          ? DynamicSchemeVariant.monochrome
          : DynamicSchemeVariant.tonalSpot,
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
