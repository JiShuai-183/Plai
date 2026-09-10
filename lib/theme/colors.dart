import 'package:flutter/material.dart';

/// Plai 品牌色板（绿色系，学生工具）。
///
/// 颜色统一在此定义，业务代码不得散落硬编码颜色；
/// 如需新颜色，先在此登记再使用。
abstract final class PlaiColors {
  /// 主题种子色（Material 3 用）：主绿。
  ///
  /// 仅**浅色主题**以它派生配色；深色主题走中性灰阶（见 `theme.dart` 的
  /// `DynamicSchemeVariant.monochrome`），故深色下本值不参与取色。
  static const Color seed = Color(0xFF43A047);

  /// 深绿：积分高分 / 强调。
  static const Color deepGreen = Color(0xFF2E7D32);

  /// 浅绿：积分低分 / 激励 / 次级强调。
  static const Color lightGreen = Color(0xFF8BC34A);

  /// 灰：未达标 / 弱化。
  static const Color mutedGrey = Color(0xFF9E9E9E);
}
