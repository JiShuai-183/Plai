import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/features/timetable/color_utils.dart';

void main() {
  test('解析带 # 的 RRGGBB', () {
    expect(colorFromHex('#4C9AFF'), const Color(0xFF4C9AFF));
  });

  test('解析不带 # 的 RRGGBB', () {
    expect(colorFromHex('4C9AFF'), const Color(0xFF4C9AFF));
  });

  test('小写输入兼容', () {
    expect(colorFromHex('#4c9aff'), const Color(0xFF4C9AFF));
  });

  test('空串与非法格式回退默认中性灰', () {
    const Color fallback = Color(0xFF9E9E9E);
    expect(colorFromHex(''), fallback);
    expect(colorFromHex(null), fallback);
    expect(colorFromHex('red'), fallback);
    expect(colorFromHex('#12'), fallback);
  });

  test('Color → #RRGGBB 往返', () {
    expect(hexFromColor(const Color(0xFF4C9AFF)), '#4C9AFF');
    expect(hexFromColor(const Color(0xFF000000)), '#000000');
  });
}
