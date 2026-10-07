import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/services/audio/complete_sound.dart';
import 'package:plai/services/notifications/notification_scheduler.dart';

/// 计数假底层输出：区分「加载/预置（setSource）」与「直接恢复（resume）」及
/// 「加载并播放（play）」，用于断言预热后不再走加载路径。
class _CountOutput implements CompletionSoundOutput {
  int setSourceCalls = 0;
  int resumeCalls = 0;
  int stopCalls = 0;
  int playCalls = 0;

  @override
  Future<void> setSource(Source source) async {
    setSourceCalls++;
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> play(Source source) async {
    playCalls++;
  }
}

/// 内存设置（预热读键用）。
class _MapSettings implements ISettingsRepository {
  _MapSettings([Map<String, String>? values]) : values = Map.of(values ?? {});

  final Map<String, String> values;

  @override
  Future<String?> getValue(String key) async => values[key];

  @override
  Future<void> setValue(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> setAll(Map<String, String> entries) async {
    values.addAll(entries);
  }

  @override
  Future<Map<String, String>> getAll() async => Map.of(values);

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }
}

/// 记录预热值 / 播放值的假播放器；可配置预热抛异常。
class _PrewarmRecorder implements CompletionSound, PrewarmableCompletionSound {
  _PrewarmRecorder({this.throwOnPrewarm = false});

  final bool throwOnPrewarm;
  final List<String> prewarmed = <String>[];
  final List<String> played = <String>[];

  @override
  Future<void> prewarm(String value) async {
    if (throwOnPrewarm) throw StateError('boom: prewarm');
    prewarmed.add(value);
  }

  @override
  Future<void> play(String path) async {
    played.add(path);
  }
}

/// 只实现播放、不支持预热的假播放器。
class _PlainRecorder implements CompletionSound {
  @override
  Future<void> play(String path) async {}
}

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

  // ------------------------------------------------------ 预热 / 已就绪直接播

  test('预热后再播不再触发加载路径：走 resume、setSource 仍为 1 次', () async {
    final _CountOutput out = _CountOutput();
    final AudioCompletionSoundPlayer player =
        AudioCompletionSoundPlayer(output: out);

    await player.prewarm('/snd/a.mp3');
    expect(out.setSourceCalls, 1); // 预热即加载一次
    expect(out.playCalls, 0);

    await player.play('/snd/a.mp3');
    expect(out.setSourceCalls, 1); // 不再加载
    expect(out.playCalls, 0); // 未走加载并播放
    expect(out.resumeCalls, 1); // 直接恢复
    expect(out.stopCalls, 1); // 连点保护仍先停
  });

  test('未预热播放走加载路径', () async {
    final _CountOutput out = _CountOutput();
    final AudioCompletionSoundPlayer player =
        AudioCompletionSoundPlayer(output: out);

    await player.play('/snd/a.mp3');
    expect(out.playCalls, 1);
    expect(out.resumeCalls, 0);
    expect(out.setSourceCalls, 0);
  });

  test('同源二次播放：第二次走已就绪 resume（免再次加载）', () async {
    final _CountOutput out = _CountOutput();
    final AudioCompletionSoundPlayer player =
        AudioCompletionSoundPlayer(output: out);

    await player.play('/snd/a.mp3');
    await player.play('/snd/a.mp3');
    expect(out.playCalls, 1);
    expect(out.resumeCalls, 1);
  });

  test('预热值与实际播放值不一致：回退加载路径播放新值', () async {
    final _CountOutput out = _CountOutput();
    final AudioCompletionSoundPlayer player =
        AudioCompletionSoundPlayer(output: out);

    await player.prewarm('/snd/a.mp3');
    await player.play('/snd/b.mp3');
    expect(out.playCalls, 1);
    expect(out.resumeCalls, 0);
  });

  test('空值不预热', () async {
    final _CountOutput out = _CountOutput();
    final AudioCompletionSoundPlayer player =
        AudioCompletionSoundPlayer(output: out);

    await player.prewarm('');
    expect(out.setSourceCalls, 0);
  });

  // --------------------------------------------------- prewarmCompletionSound

  test('键为空：不构造播放器、不预热', () async {
    final _PrewarmRecorder rec = _PrewarmRecorder();
    int factoryCalls = 0;
    await prewarmCompletionSound(_MapSettings(), () {
      factoryCalls++;
      return rec;
    });
    expect(factoryCalls, 0);
    expect(rec.prewarmed, isEmpty);
  });

  test('键非空：预热该设置值', () async {
    final _PrewarmRecorder rec = _PrewarmRecorder();
    await prewarmCompletionSound(
      _MapSettings(<String, String>{
        NotificationSettingsKeys.completeSound: '/snd/a.mp3',
      }),
      () => rec,
    );
    expect(rec.prewarmed, <String>['/snd/a.mp3']);
  });

  test('播放器不支持预热：跳过且不抛', () async {
    await expectLater(
      prewarmCompletionSound(
        _MapSettings(<String, String>{
          NotificationSettingsKeys.completeSound: '/snd/a.mp3',
        }),
        () => _PlainRecorder(),
      ),
      completes,
    );
  });

  test('预热抛异常：静默（不向外抛）', () async {
    await expectLater(
      prewarmCompletionSound(
        _MapSettings(<String, String>{
          NotificationSettingsKeys.completeSound: '/snd/a.mp3',
        }),
        () => _PrewarmRecorder(throwOnPrewarm: true),
      ),
      completes,
    );
  });
}
