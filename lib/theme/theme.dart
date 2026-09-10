import 'package:flutter/material.dart';

import 'colors.dart';

/// Plai 全局主题（Material 3）。
///
/// 三套：浅色（绿色品牌）/ 白色（纯白底 + 中性灰）/ 深色（中性灰阶）。
/// 由 `theme_controller.dart` 的 [PlaiThemeMode] 选择，在 `main.dart` 装配。
abstract final class PlaiTheme {
  // ColorScheme.fromSeed 需在 HCT 色彩空间推算整套配色，开销不小；而主题
  // 只由亮度决定、与运行时状态无关，故按亮度缓存后复用（根节点重建 /
  // themeMode 变化时不再重复计算）。
  static ThemeData? _light;
  static ThemeData? _white;
  static ThemeData? _dark;

  /// 浅色主题：绿色品牌（首次构建后缓存复用）。
  static ThemeData light() => _light ??= _build(Brightness.light);

  /// 白色主题：纯白底 + 中性灰辅助（首次构建后缓存复用）。
  static ThemeData white() => _white ??= _buildWhite();

  /// 暗色主题（首次构建后缓存复用）。
  static ThemeData dark() => _dark ??= _build(Brightness.dark);

  /// 白色主题：【纯白】底 + 中性灰辅助。
  ///
  /// 用 monochrome 变体（灰阶）而非灰色 seed——M3 的 tonalSpot 会把灰 seed
  /// 推成青色系（实测 primary 成 #006874），neutral 也带青；只有 monochrome
  /// 是真正的无色相。再显式把 surface 压成纯白：monochrome 的 surface 是
  /// #F9F9F9，而本主题定位就是「以白色为底色」。
  static ThemeData _buildWhite() {
    final ColorScheme base = ColorScheme.fromSeed(
      seedColor: PlaiColors.mutedGrey,
      brightness: Brightness.light,
      dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
    );
    return _assemble(base.copyWith(surface: const Color(0xFFFFFFFF)));
  }

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

    return _assemble(scheme);
  }

  /// 由配色方案装配 ThemeData（三套主题共用，保证组件样式一致）。
  static ThemeData _assemble(ColorScheme scheme) {
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
