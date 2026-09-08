import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/settings_repository.dart';
import '../notifications/notification_scheduler.dart';

/// 日程完成提示音播放器接口（测试可注入假实现记录触发）。
abstract interface class CompletionSound {
  /// 播放本地音频文件。
  Future<void> play(String path);
}

/// audioplayers 实现：每次播放先停上次再放，避免连点叠加。
///
/// 设置入口在设置页（选音频 → 复制到应用目录 `plai_sounds/` → 存
/// `notify.complete_sound`，见 [NotificationSettingsKeys.completeSound]）；
/// 播放点由 [playCompletionSound] 统一触发。
class AudioCompletionSoundPlayer implements CompletionSound {
  AudioCompletionSoundPlayer({AudioPlayer? player})
      : _player = player ?? AudioPlayer();

  final AudioPlayer _player;

  @override
  Future<void> play(String path) async {
    await _player.stop();
    await _player.play(DeviceFileSource(path));
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
