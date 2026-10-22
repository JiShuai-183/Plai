import 'package:flutter_test/flutter_test.dart';
import 'package:plai/services/app_update/app_update_completion.dart';
import 'package:plai/services/app_update/app_update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 2.3.4 真机 bug：更新完成后的首次打开没有弹更新公告。
/// 根因是公告只认「应用内下载安装」写下的交接记录；手动装包 / 应用商店安装时
/// 根本没有这条记录，于是什么都不弹。这组测试锁定兜底判定的三条分支。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('shouldAnnounceAfterUpgrade', () {
    test('没有历史记录且不是覆盖安装 → 不弹（全新安装）', () {
      expect(
        shouldAnnounceAfterUpgrade(
          currentVersion: '2.3.5',
          lastSeenVersion: null,
          upgraded: false,
        ),
        isFalse,
      );
    });

    test('没有历史记录但确实是覆盖安装 → 弹（手动装包升级）', () {
      expect(
        shouldAnnounceAfterUpgrade(
          currentVersion: '2.3.5',
          lastSeenVersion: null,
          upgraded: true,
        ),
        isTrue,
      );
    });

    test('记录过旧版本 → 弹', () {
      expect(
        shouldAnnounceAfterUpgrade(
          currentVersion: '2.3.5',
          lastSeenVersion: '2.3.4',
          upgraded: true,
        ),
        isTrue,
      );
    });

    test('记录的就是当前版本 → 不重复弹（即使时间戳像升级）', () {
      expect(
        shouldAnnounceAfterUpgrade(
          currentVersion: '2.3.5',
          lastSeenVersion: '2.3.5',
          upgraded: true,
        ),
        isFalse,
      );
    });
  });

  group('isUpgradeTimestamps', () {
    final DateTime installed = DateTime(2026, 10, 1, 10);

    test('全新安装（两个时间戳几乎相同）不算升级', () {
      expect(
        AppUpdateService.isUpgradeTimestamps(
          installed,
          installed.add(const Duration(seconds: 2)),
        ),
        isFalse,
      );
    });

    test('覆盖安装（更新时间明显更晚）算升级', () {
      expect(
        AppUpdateService.isUpgradeTimestamps(
          installed,
          installed.add(const Duration(days: 3)),
        ),
        isTrue,
      );
    });

    test('缺少时间戳时按「不是升级」处理', () {
      expect(AppUpdateService.isUpgradeTimestamps(null, installed), isFalse);
      expect(AppUpdateService.isUpgradeTimestamps(installed, null), isFalse);
    });
  });

  test('lastSeenVersion / recordSeenVersion 走本地偏好且可重复读写', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppUpdateCompletionStore store = AppUpdateCompletionStore();

    expect(await store.lastSeenVersion(), isNull);
    await store.recordSeenVersion('2.3.5');
    expect(await store.lastSeenVersion(), '2.3.5');
    await store.recordSeenVersion('2.3.6');
    expect(await store.lastSeenVersion(), '2.3.6');
  });
}
