import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/ai/ai_page.dart';
import 'features/schedule/schedule_page.dart';
import 'features/timetable/timetable_page.dart';
import 'services/notifications/notification_providers.dart';

/// 应用外壳：底部导航（课表 / 今日 / AI）。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _selectedIndex = 0;

  /// 已构建过的 Tab 下标。IndexedStack 会把全部子页一次性构建，导致首帧
  /// 同时加载「今日」（任务全表）与「AI」（会话全表）——首屏是课表，白付。
  /// 故未访问的 Tab 先放 0 尺寸占位，首次切到才真正构建；构建后保留在树中，
  /// 切回不丢状态、不重跑 provider（代价是首次切换时有一次加载）。
  final Set<int> _visitedTabs = <int>{0};

  @override
  void initState() {
    super.initState();
    // 应用每次冷启动后全量重排一次提醒（通知思路 §4.4「应用启动时重新注册
    // 未过期任务」）：兜底设备重启 / 应用更新 / 被系统清理后旧闹钟丢失或
    // 跨天后过期通知残留；开关关闭时调度器内部只取消不重排。失败静默。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_startupReschedule());
    });
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
    // 键盘弹出时隐藏底部导航：否则 Tab 栏虽被键盘盖住、其高度仍把
    // Tab 内容（如 AI 输入框）顶离键盘一大截。
    final bool keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    return Scaffold(
      // 键盘弹出时底部导航与 Tab 内容不整体上移跳动（如课表跳周弹窗）。
      resizeToAvoidBottomInset: false,
      body: IndexedStack(
        index: _selectedIndex,
        children: <Widget>[
          for (int i = 0; i < _pages.length; i++)
            if (_visitedTabs.contains(i)) _pages[i] else const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: keyboardOpen
          ? null
          : NavigationBar(
              height: 64,
              selectedIndex: _selectedIndex,
              onDestinationSelected: (int index) {
                setState(() {
                  _selectedIndex = index;
                  _visitedTabs.add(index);
                });
              },
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
  }
}
