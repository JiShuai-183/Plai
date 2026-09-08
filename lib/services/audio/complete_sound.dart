import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/settings_repository.dart';
import '../notifications/notification_scheduler.dart';

/// 日程完成提示音播放器接口（测试可注入假实现记录触发）。
abstract interface class CompletionSound {
  /// 播放本地音频文件。
  Future<void> play(String path);
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

/// audioplayers 实现：每次播放先停上次再放，避免连点叠加。
///
/// 设置值两种来源（设置页写入 `notify.complete_sound`）：
/// - 内置：`asset:<key>` → [AssetSource]（`assets/audio/<key>.mp3`）；
/// - 自选文件：本地绝对路径 → [DeviceFileSource]（设置页复制进应用目录防
///   源文件移动失效）。
/// 播放点由 [playCompletionSound] 统一触发。
class AudioCompletionSoundPlayer implements CompletionSound {
  AudioCompletionSoundPlayer({AudioPlayer? player})
      : _player = player ?? AudioPlayer();

  final AudioPlayer _player;

  @override
  Future<void> play(String value) async {
    await _player.stop();
    await _player.play(_toSource(value));
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
