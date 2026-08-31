import 'package:flutter/material.dart';

/// 未设置/非法课程颜色时的默认色（中性灰，与已结束灰一致）。
const Color _defaultCourseColor = Color(0xFF9E9E9E);

/// 解析课程颜色 `#RRGGBB`（可带或不带 `#`，兼容大小写）为 [Color]。
///
/// 空串或非法格式回退 [fallback]（缺省为中性灰），不抛异常。
Color colorFromHex(String? hex, {Color? fallback}) {
  if (hex == null || hex.trim().isEmpty) {
    return fallback ?? _defaultCourseColor;
  }
  String value = hex.trim();
  if (value.startsWith('#')) value = value.substring(1);
  if (value.length != 6) return fallback ?? _defaultCourseColor;
  final int? parsed = int.tryParse(value, radix: 16);
  if (parsed == null) return fallback ?? _defaultCourseColor;
  return Color(0xFF000000 | parsed);
}

/// [Color] → 大写 `#RRGGBB`（数据层存储/交换格式）。
String hexFromColor(Color color) {
  final int rgb = color.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}
