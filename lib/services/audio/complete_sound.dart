import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/settings_repository.dart';
import '../notifications/notification_scheduler.dart';

/// 日程完成提示音播放器接口（测试可注入假实现记录触发）。
abstract interface class CompletionSound {
  /// 播放本地音频文件。
  Future<void> play(String path);
}

/// 可预热的完成提示音播放器：提前加载 / 解码音源，使随后 [CompletionSound.play]
/// 走「已就绪直接播」，省去首次解码与平台通道延迟。
///
/// 不实现本接口的播放器（如测试假实现）会被 [prewarmCompletionSound] 跳过。
abstract interface class PrewarmableCompletionSound {
  /// 预置 [value]（设置值）对应的音源。空值不预置。
  Future<void> prewarm(String value);
}

/// 完成提示音底层音频输出：只暴露完成音所需的最小动作，抽出来便于测试注入
/// 计数假实现（断言「预热后播放不再走加载路径」）。
abstract interface class CompletionSoundOutput {
  /// 预置 / 加载并解码音源（预热），供随后 [resume] 直接播。
  Future<void> setSource(Source source);

  /// 从当前位置播放已预置音源（预热后走这条，省去加载）。
  Future<void> resume();

  /// 停止播放（连点保护：先停再放，避免叠加）。[ReleaseMode.stop] 下保留音源。
  Future<void> stop();

  /// 加载并播放音源（未预热时的回退路径）。
  Future<void> play(Source source);
}

/// audioplayers 实现。
///
/// 固定 `ReleaseMode.stop`：默认的 `ReleaseMode.release` 会在每次 [stop]
/// （连点保护）时释放已预置音源，预热即失效；stop 模式只暂停并回到起点，
/// 音源与解码结果保留，故 [resume] 可即刻出声。
class _AudioPlayerOutput implements CompletionSoundOutput {
  _AudioPlayerOutput(this._player) {
    unawaited(_player.setReleaseMode(ReleaseMode.stop));
  }

  final AudioPlayer _player;

  @override
  Future<void> setSource(Source source) => _player.setSource(source);

  @override
  Future<void> resume() => _player.resume();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> play(Source source) => _player.play(source);
}

/// 内置完成提示音的设置值前缀：`asset:<key>` 表示引用内置音频。
const String kBuiltinSoundScheme = 'asset:';

/// 内置预设完成提示音：asset 文件词干（`assets/audio/<key>.mp3`）→ 展示名。
const Map<String, String> kBuiltinCompleteSounds = <String, String>{
  'steam_achievement': 'steam成就',
};

/// 设置值是否引用内置预设（`asset:...`）。
bool isBuiltinCompleteSound(String value) =>
    value.startsWith(kBuiltinSoundScheme);

/// 内置预设展示名：由设置值（`asset:key`）在 [kBuiltinCompleteSounds] 查；
/// 非内置或未知 key 原样返回。
String builtinCompleteSoundLabel(String value) {
  final String key = value.substring(kBuiltinSoundScheme.length);
  return kBuiltinCompleteSounds[key] ?? value;
}

/// audioplayers 实现：每次播放先停上次再放，避免连点叠加；支持预热。
///
/// 设置值两种来源（设置页写入 `notify.complete_sound`）：
/// - 内置：`asset:<key>` → [AssetSource]（`assets/audio/<key>.mp3`）；
/// - 自选文件：本地绝对路径 → [DeviceFileSource]（设置页复制进应用目录防
///   源文件移动失效）。
/// 播放点由 [playCompletionSound] 统一触发。
class AudioCompletionSoundPlayer
    implements CompletionSound, PrewarmableCompletionSound {
  AudioCompletionSoundPlayer({
    AudioPlayer? player,
    CompletionSoundOutput? output,
  }) : _output = output ?? _AudioPlayerOutput(player ?? AudioPlayer());

  final CompletionSoundOutput _output;

  /// 已预置音源的设置值；与本次设置值一致时走 [resume] 直接播，不再加载。
  String? _preloaded;

  @override
  Future<void> prewarm(String value) async {
    if (value.isEmpty) return;
    await _output.setSource(_toSource(value));
    _preloaded = value;
  }

  @override
  Future<void> play(String value) async {
    // 连点保护：先停上次再播，避免叠加（ReleaseMode.stop 下不丢预置结果）。
    await _output.stop();
    if (_preloaded == value) {
      await _output.resume();
      return;
    }
    await _output.play(_toSource(value));
    // 播放即已加载：下次同源点击可直接 resume（顺带获得之后的加速）。
    _preloaded = value;
  }

  Source _toSource(String value) {
    if (isBuiltinCompleteSound(value)) {
      final String key = value.substring(kBuiltinSoundScheme.length);
      return AssetSource('audio/$key.mp3');
    }
    return DeviceFileSource(value);
  }
}

/// 完成提示音播放器 Provider。
final completionSoundPlayerProvider = Provider<CompletionSound>(
  (ref) => AudioCompletionSoundPlayer(),
);

/// 完成动作触发播放：设置键为空不播；任何读键/音频异常静默，
/// 不阻断任务状态保存（完成事件正常流程）。
Future<void> playCompletionSound(
  WidgetRef ref,
  ISettingsRepository settings,
) async {
  try {
    final String? path =
        await settings.getValue(NotificationSettingsKeys.completeSound);
    if (path == null || path.isEmpty) return;
    await ref.read(completionSoundPlayerProvider).play(path);
  } catch (_) {
    // 静默：音频失败不影响任务完成。
  }
}

/// 预热完成提示音：设置值非空时预置音源，使随后 [playCompletionSound] 走
/// 「已就绪直接播」，省去首次解码与平台通道延迟。
///
/// [player] 为惰性工厂：设置键为空 / 播放器不支持预热（未实现
/// [PrewarmableCompletionSound]）时不构造播放器。每次完成仍重新读键（读键很
/// 便宜，主要延迟在解码与平台通道），设置改动后由调用方重新预热即可生效；
/// 任何异常静默（预热失败只少一次加速，不影响完成音功能）。
Future<void> prewarmCompletionSound(
  ISettingsRepository settings,
  CompletionSound Function() player,
) async {
  try {
    final String? path =
        await settings.getValue(NotificationSettingsKeys.completeSound);
    if (path == null || path.isEmpty) return;
    // 声明为 Object 才能把「不支持预热的播放器」也用同一段代码筛掉
    // （CompletionSound 与 PrewarmableCompletionSound 相互独立，无子类型关系）。
    final Object sound = player();
    if (sound is PrewarmableCompletionSound) {
      await sound.prewarm(path);
    }
  } catch (_) {
    // 静默：预热失败不影响任务完成音。
  }
}
