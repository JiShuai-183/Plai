import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/data/models/task.dart';
import 'package:plai/features/schedule/calendar_page.dart';
import 'package:plai/features/schedule/schedule_providers.dart';
import 'package:plai/features/schedule/task_list_tile.dart';

void main() {
  DateTime today() {
    final DateTime n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  /// 打开日历即应看到「今天」的格子。
  ///
  /// 回归防线：矮视口（默认 800x600、横屏、大字体）下固定高宽比会让网格溢出，
  /// 末行整体不被构建且不可滚动，「今天」若落在末行则既不可见也不可点。
  /// 用 [DateTime.now] 动态推导当天文本，不写死具体日期。
  void expectTodayCellVisible(WidgetTester tester, DateTime d) {
    final Finder cell = find.text('${d.day}');
    expect(cell, findsOneWidget, reason: '打开日历应已构建「今天」格子');
    final Size screen =
        tester.view.physicalSize / tester.view.devicePixelRatio;
    final Rect r = tester.getRect(cell);
    expect(r.top, greaterThanOrEqualTo(0.0));
    expect(r.bottom, lessThanOrEqualTo(screen.height),
        reason: '「今天」格子应在可视区内，无需滚动');
  }

  Widget wrap({
    required List<Task> tasks,
    Map<int, Set<DateTime>> doneMap = const {},
  }) {
    return ProviderScope(
      overrides: [
        tasksProvider.overrideWith((ref) async => tasks),
        dailyDoneMapProvider.overrideWith((ref) async => doneMap),
      ],
      child: const MaterialApp(home: CalendarPage()),
    );
  }

  testWidgets('span 跨期：区间内某天弹层列出该任务', (WidgetTester tester) async {
    final DateTime d = today();
    final Task span = Task(
      id: 1,
      title: '暑期阅读',
      type: TaskType.span,
      startDate: d.subtract(const Duration(days: 2)),
      dueDate: d.add(const Duration(days: 2)),
    );

    await tester.pumpWidget(wrap(tasks: [span]));
    await tester.pumpAndSettle();

    // 打开即应看到今天（位于区间中间），再点它 → 弹层应列出 span。
    expectTodayCellVisible(tester, d);
    await tester.tap(find.text('${d.day}'));
    await tester.pumpAndSettle();

    expect(find.textContaining('的任务'), findsOneWidget);
    expect(find.text('暑期阅读'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('daily：当天已打卡 → 弹层行勾选框为真', (WidgetTester tester) async {
    final DateTime d = today();
    final Task daily = Task(
      id: 7,
      title: '每日喝水',
      type: TaskType.daily,
      startDate: d.subtract(const Duration(days: 1)),
      dueDate: d.add(const Duration(days: 1)),
    );

    await tester.pumpWidget(wrap(
      tasks: [daily],
      doneMap: <int, Set<DateTime>>{7: <DateTime>{d}},
    ));
    await tester.pumpAndSettle();

    expectTodayCellVisible(tester, d);
    await tester.tap(find.text('${d.day}'));
    await tester.pumpAndSettle();

    // 已完成：标题叠两层（下层普通 + 上层带删除线、随扫描裁剪）。
    expect(find.text('每日喝水'), findsNWidgets(2));
    expect(find.byKey(TaskListTile.titleSweepKey), findsOneWidget);
    final Checkbox box = tester.widget<Checkbox>(find.byType(Checkbox));
    expect(box.value, isTrue);
    expect(tester.takeException(), isNull);
  });
}
