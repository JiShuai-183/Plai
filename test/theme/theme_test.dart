import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/theme/theme.dart';
import 'package:plai/theme/theme_controller.dart';

void main() {
  test('亮/暗/白主题各只构建一次并缓存复用', () {
    // 根节点每次重建都会取用主题，重复构建会反复跑 ColorScheme.fromSeed。
    expect(identical(PlaiTheme.light(), PlaiTheme.light()), isTrue);
    expect(identical(PlaiTheme.dark(), PlaiTheme.dark()), isTrue);
    expect(identical(PlaiTheme.white(), PlaiTheme.white()), isTrue);
    expect(identical(PlaiTheme.white(), PlaiTheme.light()), isFalse);
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

  test('浅色主题保留品牌绿（不随中性化一起改掉）', () {
    final Color primary = PlaiTheme.light().colorScheme.primary;
    expect(primary.g, greaterThan(primary.r));
    expect(primary.g, greaterThan(primary.b));
  });

  test('白色主题：纯白底 + 中性灰辅助', () {
    final ColorScheme scheme = PlaiTheme.white().colorScheme;
    expect(scheme.brightness, Brightness.light);
    // 底色是纯白——区别于浅色主题泛绿的浅白（实测 #F7FBF1）。
    expect(scheme.surface, const Color(0xFFFFFFFF));
    expect(PlaiTheme.light().colorScheme.surface,
        isNot(const Color(0xFFFFFFFF)));

    // 辅助色为中性灰：无色相倾向。
    final Map<String, Color> roles = <String, Color>{
      'primary': scheme.primary,
      'primaryContainer': scheme.primaryContainer,
      'secondaryContainer': scheme.secondaryContainer,
      'onSurface': scheme.onSurface,
      'outlineVariant': scheme.outlineVariant,
    };
    for (final MapEntry<String, Color> e in roles.entries) {
      expect(e.value.r, closeTo(e.value.g, 0.02),
          reason: '${e.key} 应为中性灰，实际 ${e.value}');
      expect(e.value.g, closeTo(e.value.b, 0.02),
          reason: '${e.key} 应为中性灰，实际 ${e.value}');
    }
  });

  test('主题模式持久化串：四档往返，旧值与未知值回退跟随系统', () {
    for (final PlaiThemeMode m in PlaiThemeMode.values) {
      expect(PlaiThemeMode.fromStorage(m.name), m);
    }
    // 旧版本只写过 system/light/dark，天然兼容。
    expect(PlaiThemeMode.fromStorage('light'), PlaiThemeMode.light);
    expect(PlaiThemeMode.fromStorage('dark'), PlaiThemeMode.dark);
    expect(PlaiThemeMode.fromStorage(null), PlaiThemeMode.system);
    expect(PlaiThemeMode.fromStorage('rainbow'), PlaiThemeMode.system);
  });
}
