import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/data/models/task.dart';
import 'package:plai/features/schedule/task_filter_sheet.dart';

/// 回调捕获容器（onChanged 最新一次入参）。
class _Capture {
  TaskFilterSelection? value;
}

TaskFilterSelection _all() => TaskFilterSelection(types: TaskType.values.toSet());

Widget _wrap(TaskFilterSelection initial, _Capture capture) {
  return MaterialApp(
    home: Scaffold(
      body: TaskFilterSheet(
        current: initial,
        onChanged: (TaskFilterSelection next) => capture.value = next,
      ),
    ),
  );
}

void main() {
  testWidgets('默认全选 + 完成状态三选齐备，含查看全部入口', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(_all(), _Capture()));
    await tester.pump();

    expect(find.byType(CheckboxListTile), findsNWidgets(4));
    expect(find.text('常用筛选'), findsOneWidget);
    expect(find.text('显示全部'), findsOneWidget);
    expect(find.text('查看全部任务'), findsOneWidget);
    expect(find.text('完成状态'), findsOneWidget);

    for (final TaskType type in TaskType.values) {
      final CheckboxListTile tile = tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, type.label),
      );
      expect(tile.value, isTrue, reason: '${type.label} 应默认选中');
    }
    for (final String label in <String>['全部', '未完成', '已完成']) {
      final ChoiceChip chip =
          tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));
      if (label == '全部') expect(chip.selected, isTrue);
    }
    // 默认全滤关 → 「显示全部」禁用。
    final TextButton reset =
        tester.widget<TextButton>(find.widgetWithText(TextButton, '显示全部'));
    expect(reset.onPressed, isNull);
  });

  testWidgets('取消每日打卡：回调返回不含 daily 的类型集', (WidgetTester tester) async {
    final _Capture capture = _Capture();
    await tester.pumpWidget(_wrap(_all(), capture));
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
    expect(capture.value!.types.contains(TaskType.daily), isFalse);
    expect(capture.value!.types.length, TaskType.values.length - 1);
    expect(capture.value!.completion, isNull);
  });

  testWidgets('选完成状态「已完成」：回调 completion=true', (WidgetTester tester) async {
    final _Capture capture = _Capture();
    await tester.pumpWidget(_wrap(_all(), capture));
    await tester.pump();

    await tester.tap(find.widgetWithText(ChoiceChip, '已完成'));
    await tester.pump();

    expect(capture.value, isNotNull);
    expect(capture.value!.completion, isTrue);
    expect(capture.value!.types.length, TaskType.values.length);
  });

  testWidgets('显示全部：类型全选 + 完成状态回全部', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(
      const TaskFilterSelection(
        types: <TaskType>{TaskType.scheduled},
        completion: true,
      ),
      _Capture(),
    ));
    await tester.pump();

    expect(
      tester
          .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, '待办任务'))
          .value,
      isFalse,
    );
    final ChoiceChip doneChip = tester
        .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '已完成'));
    expect(doneChip.selected, isTrue);

    await tester.tap(find.text('显示全部'));
    await tester.pump();

    for (final TaskType type in TaskType.values) {
      final CheckboxListTile tile = tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, type.label),
      );
      expect(tile.value, isTrue, reason: '显示全部后 ${type.label} 应选中');
    }
    final ChoiceChip allChip =
        tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '全部'));
    expect(allChip.selected, isTrue);
  });
}
