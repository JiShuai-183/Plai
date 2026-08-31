import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/semester.dart';
import 'timetable_providers.dart';
import 'week_view.dart';

/// 课表某周页（通知点击「上课提醒」的深链目标）。
///
/// 路由参数：[AppRoutes.timetableWeek] 携带 `int` 周次，定位到对应周的
/// 周视图；参数缺失时定位到当前周。未登记前通知深链自动回退根路由。
class TimetableWeekPage extends ConsumerWidget {
  const TimetableWeekPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Object? args = ModalRoute.of(context)?.settings.arguments;
    final int? week = args is int ? args : null;

    final AsyncValue<Semester?> semesterAsync =
        ref.watch(currentSemesterProvider);
    return semesterAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (_, _) => const Scaffold(
        body: Center(child: Text('课表加载失败')),
      ),
      data: (Semester? semester) {
        if (semester == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('课表')),
            body: const Center(child: Text('暂无学期')),
          );
        }
        return Scaffold(
          appBar: AppBar(title: Text(week == null ? semester.name : '第 $week 周')),
          body: WeekView(
            semester: semester,
            initialWeek: week,
            key: ValueKey('${semester.id}-$week'),
          ),
        );
      },
    );
  }
}
