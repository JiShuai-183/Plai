import 'package:flutter_test/flutter_test.dart';
import 'package:plai/services/audio/complete_sound.dart';

/// 内置完成提示音「asset 标记 + 展示名」纯逻辑测试。
void main() {
  test('内置预设表包含 steam成就（asset 文件词干）', () {
    expect(kBuiltinCompleteSounds, contains('steam_achievement'));
    expect(kBuiltinCompleteSounds['steam_achievement'], 'steam成就');
  });

  test('asset 标记判定：asset: 前缀为内置，本地路径不是', () {
    expect(isBuiltinCompleteSound('asset:steam_achievement'), isTrue);
    expect(isBuiltinCompleteSound('/doc/plai_sounds/complete.mp3'), isFalse);
  });

  test('展示名：内置查表、未知 key / 非内置原样返回', () {
    expect(
      builtinCompleteSoundLabel('asset:steam_achievement'),
      'steam成就',
    );
    expect(builtinCompleteSoundLabel('asset:missing_key'), 'asset:missing_key');
    expect(
      builtinCompleteSoundLabel('/doc/plai_sounds/complete.mp3'),
      '/doc/plai_sounds/complete.mp3',
    );
  });
}
