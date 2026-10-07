import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 底部导航各 tab 的下标（AppShell 与各页面共用，避免各自写死数字）。
const int kTimetableTabIndex = 0; // 课表（周视图）
const int kTodayTabIndex = 1; // 今日（日视图）
const int kAiTabIndex = 2; // AI

/// Tab 重按信号：**再次点击当前已选中的 tab** 时自增。
///
/// 页面用 `ref.listen(tabReselectProvider(kYourTabIndex), …)` 监听并复位自己
/// 的视图（如课表回到本周、今日回到今天）。自增而非布尔，保证连按多次每次都会
/// 通知到监听者。
final tabReselectProvider =
    NotifierProvider.family<TabReselectNotifier, int, int>(
      TabReselectNotifier.new,
    );

class TabReselectNotifier extends FamilyNotifier<int, int> {
  @override
  int build(int tabIndex) => 0;

  void bump() => state = state + 1;
}
