import 'package:flutter_test/flutter_test.dart';
import 'package:plai/services/app_update/app_update_flow.dart';
import 'package:plai/services/app_update/app_update_service.dart';

/// 启动检查必须重试：冷启动后 3 秒时网络/握手常常还没就绪，只试一次就会出现
/// 「启动 3 秒后什么都没发生」（2.3.2 / 2.3.3 真机反馈）。
void main() {
  const AppUpdateCheckResult failed =
      AppUpdateCheckResult.failed('更新服务器响应超时，请稍后重试。');

  test('前两次失败、第三次成功时返回成功结果', () async {
    int calls = 0;
    final AppUpdateCheckResult result = await checkForUpdateWithRetry(
      () async {
        calls++;
        if (calls < 3) return failed;
        return const AppUpdateCheckResult.upToDate('2.3.3');
      },
      backoff: const <Duration>[Duration.zero, Duration.zero],
    );
    expect(calls, 3);
    expect(result.status, AppUpdateCheckStatus.upToDate);
  });

  test('一直失败时用尽重试次数并返回最后一次失败原因', () async {
    int calls = 0;
    final AppUpdateCheckResult result = await checkForUpdateWithRetry(
      () async {
        calls++;
        return failed;
      },
      backoff: const <Duration>[Duration.zero, Duration.zero, Duration.zero],
    );
    expect(calls, 4);
    expect(result.status, AppUpdateCheckStatus.failed);
    expect(result.message, contains('超时'));
  });

  test('发现新版本时立刻返回，不再重试', () async {
    int calls = 0;
    final AppUpdateCheckResult result = await checkForUpdateWithRetry(
      () async {
        calls++;
        return AppUpdateCheckResult.updateAvailable(
          AppUpdateCandidate(
            currentVersion: '2.3.2',
            version: '2.3.3',
            notes: '',
            announcement: '',
            platform: AppUpdatePlatform.android,
            asset: AppUpdateAsset(
              name: 'Plai-android-2.3.3.apk',
              path: 'releases/2.3.3/Plai-android-2.3.3.apk',
              size: 100,
              sha256: 'a' * 64,
            ),
          ),
        );
      },
      backoff: const <Duration>[Duration.zero],
    );
    expect(calls, 1);
    expect(result.hasUpdate, isTrue);
  });

  test('页面已销毁时不再继续重试', () async {
    int calls = 0;
    final AppUpdateCheckResult result = await checkForUpdateWithRetry(
      () async {
        calls++;
        return failed;
      },
      backoff: const <Duration>[Duration.zero],
      isActive: () => false,
    );
    expect(calls, 1);
    expect(result.status, AppUpdateCheckStatus.failed);
  });
}
