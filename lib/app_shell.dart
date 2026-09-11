import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/ai/ai_page.dart';
import 'features/ai/ai_providers.dart';
import 'features/schedule/schedule_page.dart';
import 'features/schedule/schedule_providers.dart';
import 'features/timetable/timetable_page.dart';
import 'features/timetable/timetable_providers.dart';
import 'routes/app_routes.dart';
import 'services/notifications/notification_providers.dart';
import 'shared/layout_breakpoints.dart';
import 'shared/desktop_window_controls.dart';

/// 应用外壳：底部导航（课表 / 今日 / AI）。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  /// 冷启动落地 Tab：**今日**（使用频率最高，打开即可用）。
  /// 底部导航顺序仍是 课表/今日/AI，只改落地页、不改导航顺序。
  int _selectedIndex = _todayTabIndex;

  /// 已构建过的 Tab 下标。IndexedStack 会把全部子页一次性构建，导致首帧
  /// 同时加载三个模块的数据；故未访问的 Tab 先放 0 尺寸占位，首次切到才
  /// 真正构建；构建后保留在树中，切回不丢状态、不重跑 provider。
  final Set<int> _visitedTabs = <int>{_todayTabIndex};

  /// 「今日」在底部导航中的下标（落地页）。
  static const int _todayTabIndex = 1;

  @override
  void initState() {
    super.initState();
    // 首帧之后再干两件不阻塞首屏的事：
    // 1) 按使用频率预热各 Tab 数据（今日 → 课表 → AI）；
    // 2) 冷启动全量重排一次提醒（通知思路 §4.4「应用启动时重新注册未过期
    //    任务」）：兜底设备重启 / 应用更新 / 被系统清理后旧闹钟丢失或跨天后
    //    过期通知残留；开关关闭时调度器内部只取消不重排。失败静默。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_startupWarmup());
      unawaited(_startupReschedule());
    });
  }

  /// 首帧后按使用频率逐次预热数据，让切 Tab 不再出现加载态。
  ///
  /// 严格串行 await：逐个把查询交给 sqflite，避免一次性把全部读拍到 UI
  /// isolate 上；顺序即优先级，对应 今日 → 课表 → AI。
  ///
  /// 注：「课表」的数据（学期 / 课程 / 停课 / 节次）本身就是今日视图依赖链的
  /// 上游，会随第一步一并拉齐，故不重复列一步。
  Future<void> _startupWarmup() async {
    await _warmQuietly(ref.read(todayViewProvider.future)); // 今日（含课表依赖链）
    await _warmQuietly(ref.read(dailyDoneMapProvider.future));
    await _warmQuietly(ref.read(timetableStatusSettingsProvider.future));
    await _warmQuietly(ref.read(sessionsProvider.future)); // AI
  }

  /// 预热只是优化：失败必须静默，页面的加载与报错逻辑仍是唯一事实来源。
  Future<void> _warmQuietly(Future<Object?> warming) async {
    try {
      await warming;
    } catch (_) {
      // 忽略：预热失败不影响启动。
    }
  }

  Future<void> _startupReschedule() async {
    try {
      await ref.read(notificationSchedulerProvider).rescheduleAll();
    } catch (_) {
      // 启动重排失败不阻断 App（通知开关关闭 / 数据读取失败等场景）。
    }
  }

  static const List<Widget> _pages = [
    TimetablePage(),
    SchedulePage(),
    AiPage(),
  ];

  @override
  Widget build(BuildContext context) {
    final Widget pageStack = IndexedStack(
      index: _selectedIndex,
      children: <Widget>[
        for (int i = 0; i < _pages.length; i++)
          if (_visitedTabs.contains(i)) _pages[i] else const SizedBox.shrink(),
      ],
    );

    // 键盘弹出时隐藏底部导航：否则 Tab 栏虽被键盘盖住、其高度仍把
    // Tab 内容（如 AI 输入框）顶离键盘一大截。
    final bool keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool isDesktop = constraints.maxWidth >= kDesktopLayoutBreakpoint;
        final Widget responsivePageStack = DesktopLayoutScope(
          isDesktop: isDesktop,
          child: pageStack,
        );
        return Scaffold(
          // 键盘弹出时底部导航与 Tab 内容不整体上移跳动（如课表跳周弹窗）。
          resizeToAvoidBottomInset: false,
          body: isDesktop
              ? Column(
                  children: <Widget>[
                    if (Platform.isWindows) const DesktopWindowControls(),
                    Expanded(
                      child: Row(
                        children: <Widget>[
                          _DesktopNavigationRail(
                            selectedIndex: _selectedIndex,
                            onSelected: _selectTab,
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(child: responsivePageStack),
                        ],
                      ),
                    ),
                  ],
                )
              : responsivePageStack,
          bottomNavigationBar: isDesktop || keyboardOpen
              ? null
              : NavigationBar(
                  height: 64,
                  selectedIndex: _selectedIndex,
                  onDestinationSelected: _selectTab,
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.calendar_view_week_outlined),
                      selectedIcon: Icon(Icons.calendar_view_week),
                      label: '课表',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.today_outlined),
                      selectedIcon: Icon(Icons.today),
                      label: '今日',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.auto_awesome_outlined),
                      selectedIcon: Icon(Icons.auto_awesome),
                      label: 'AI',
                    ),
                  ],
                ),
        );
      },
    );
  }

  void _selectTab(int index) {
    setState(() {
      _selectedIndex = index;
      _visitedTabs.add(index);
    });
  }
}

/// 宽屏导航：将手机底栏转换为固定工作区侧边栏，不改变页面与状态的归属。
class _DesktopNavigationRail extends StatelessWidget {
  const _DesktopNavigationRail({
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 232,
      child: Column(
        children: <Widget>[
          Expanded(
            child: NavigationRail(
              extended: true,
              minExtendedWidth: 232,
              minWidth: 80,
              selectedIndex: selectedIndex,
              onDestinationSelected: onSelected,
              // 品牌标识现在位于窗口左上标题栏；保留少量留白稳定导航起点。
              leading: const SizedBox(height: 20),
              destinations: const <NavigationRailDestination>[
                NavigationRailDestination(
                  icon: Icon(Icons.calendar_view_week_outlined),
                  selectedIcon: Icon(Icons.calendar_view_week),
                  label: Text('课表'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.today_outlined),
                  selectedIcon: Icon(Icons.today),
                  label: Text('今日'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.auto_awesome_outlined),
                  selectedIcon: Icon(Icons.auto_awesome),
                  label: Text('AI'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Tooltip(
            message: '设置',
            child: InkWell(
              onTap: () => Navigator.of(context).pushNamed(AppRoutes.settings),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 18, 24, 20),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.settings_outlined,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 16),
                    Text(
                      '设置',
                      style: Theme.of(context).textTheme.labelLarge
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
