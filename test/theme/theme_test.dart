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

  test('深色主题为中性灰阶：无绿色调（气泡/提示条不再泛绿）', () {
    final ColorScheme dark = PlaiTheme.dark().colorScheme;
    // 这三类正是用户反馈「深色下仍泛浅绿」的取色来源：
    // 强调色、AI 气泡底、SnackBar（报错提示）底。
    final Map<String, Color> roles = <String, Color>{
      'primary': dark.primary,
      'primaryContainer': dark.primaryContainer,
      'inverseSurface': dark.inverseSurface,
      'surface': dark.surface,
      'surfaceContainerHighest': dark.surfaceContainerHighest,
    };
    for (final MapEntry<String, Color> e in roles.entries) {
      expect(e.value.r, closeTo(e.value.g, 0.02),
          reason: '${e.key} 应无色彩倾向，实际 ${e.value}');
      expect(e.value.g, closeTo(e.value.b, 0.02),
          reason: '${e.key} 应无色彩倾向，实际 ${e.value}');
    }
  });

  test('浅色主题保留品牌绿（不随深色中性化一起改掉）', () {
    final Color primary = PlaiTheme.light().colorScheme.primary;
    expect(primary.g, greaterThan(primary.r));
    expect(primary.g, greaterThan(primary.b));
  });
}
