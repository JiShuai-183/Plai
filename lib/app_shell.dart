import 'package:flutter/material.dart';

import 'features/ai/ai_page.dart';
import 'features/schedule/schedule_page.dart';
import 'features/timetable/timetable_page.dart';

/// 应用外壳：底部导航（课表 / 今日 / AI）。
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;

  static const List<Widget> _pages = [
    TimetablePage(),
    SchedulePage(),
    AiPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 键盘弹出时底部导航与 Tab 内容不整体上移跳动（如课表跳周弹窗）。
      resizeToAvoidBottomInset: false,
      body: IndexedStack(index: _selectedIndex, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (int index) {
          setState(() => _selectedIndex = index);
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
            icon: Icon(Icons.smart_toy_outlined),
            selectedIcon: Icon(Icons.smart_toy),
            label: 'AI',
          ),
        ],
      ),
    );
  }
}
