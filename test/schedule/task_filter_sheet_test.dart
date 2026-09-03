import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/data/models/task.dart';
import 'package:plai/features/schedule/task_filter_sheet.dart';

/// 回调捕获容器（onChanged 最新一次入参）。
class _Capture {
  Set<TaskType>? value;
}

Widget _wrap(Set<TaskType> initial, _Capture capture) {
  return MaterialApp(
    home: Scaffold(
      body: TaskFilterSheet(
        initial: initial,
        onChanged: (Set<TaskType> next) => capture.value = next,
      ),
    ),
  );
}

void main() {
  testWidgets('默认 4 类全选，含查看全部入口', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(TaskType.values.toSet(), _Capture()));
    await tester.pump();

    expect(find.byType(CheckboxListTile), findsNWidgets(4));
    expect(find.text('任务类型'), findsOneWidget);
    expect(find.text('显示全部'), findsOneWidget);
    expect(find.text('查看全部任务'), findsOneWidget);

    for (final TaskType type in TaskType.values) {
      final CheckboxListTile tile = tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, type.label),
      );
      expect(tile.value, isTrue, reason: '${type.label} 应默认选中');
    }
  });

  testWidgets('取消每日打卡：回调返回不含 daily 的集合', (WidgetTester tester) async {
    final _Capture capture = _Capture();
    await tester.pumpWidget(_wrap(TaskType.values.toSet(), capture));
    await tester.pump();

    await tester.tap(find.widgetWithText(CheckboxListTile, '每日打卡'));
    await tester.pump();

    expect(
      tester
          .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, '每日打卡'))
          .value,
      isFalse,
    );
    expect(capture.value, isNotNull);
    expect(capture.value!.contains(TaskType.daily), isFalse);
    expect(capture.value!.length, TaskType.values.length - 1);
  });

  testWidgets('显示全部恢复全选', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(<TaskType>{TaskType.scheduled}, _Capture()));
    await tester.pump();

    expect(
      tester
          .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, '待办任务'))
          .value,
      isFalse,
    );

    await tester.tap(find.text('显示全部'));
    await tester.pump();

    for (final TaskType type in TaskType.values) {
      final CheckboxListTile tile = tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, type.label),
      );
      expect(tile.value, isTrue, reason: '显示全部后 ${type.label} 应选中');
    }
  });
}
