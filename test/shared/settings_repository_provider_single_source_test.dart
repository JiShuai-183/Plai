import 'package:flutter_test/flutter_test.dart';
import 'package:plai/features/settings/settings_providers.dart' as settings;
import 'package:plai/features/timetable/timetable_providers.dart' as timetable;

/// 锁定不变式：`settingsRepositoryProvider` 只在「设置」模块定义一处，
/// 课表模块仅 `export` 转出同一对象。
///
/// 历史遗留：课表模块曾自带一份逐字相同的副本（两个不同的 `Provider` 对象），
/// 下游靠 `hide` 消歧，测试只覆盖其中一个时会静默走生产单例。此用例比较的是
/// **Provider 对象本身**（不是它的值），两处路径必须拿到同一实例。
void main() {
  test('settingsRepositoryProvider 在设置模块与课表模块是同一个对象', () {
    expect(
      identical(
        settings.settingsRepositoryProvider,
        timetable.settingsRepositoryProvider,
      ),
      isTrue,
    );
  });
}
