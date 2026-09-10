import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/theme/theme.dart';

void main() {
  test('亮/暗主题各只构建一次并缓存复用', () {
    // 根节点每次重建都会取用主题，重复构建会反复跑 ColorScheme.fromSeed。
    expect(identical(PlaiTheme.light(), PlaiTheme.light()), isTrue);
    expect(identical(PlaiTheme.dark(), PlaiTheme.dark()), isTrue);
    expect(identical(PlaiTheme.light(), PlaiTheme.dark()), isFalse);
  });

  test('亮/暗主题的亮度正确且均为 Material 3', () {
    expect(PlaiTheme.light().colorScheme.brightness, Brightness.light);
    expect(PlaiTheme.dark().colorScheme.brightness, Brightness.dark);
    expect(PlaiTheme.light().useMaterial3, isTrue);
    expect(PlaiTheme.dark().useMaterial3, isTrue);
  });
}
