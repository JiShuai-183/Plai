import 'package:flutter/material.dart';

import '../../shared/placeholder_view.dart';

/// 今日页（日程）占位。
///
/// plai-schedule agent 在此实现：任务 CRUD、定点日程/待办、完成打卡、
/// 优先级、今日视图、日历视图。
class SchedulePage extends StatelessWidget {
  const SchedulePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderView(
      title: '今日',
      description: '任务 CRUD、定点日程/待办、完成打卡、今日视图、日历视图（plai-schedule）',
    );
  }
}
