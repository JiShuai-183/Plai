import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/features/schedule/task_list_tile.dart';

void main() {
  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: ListView(children: [child])));

  Task dailyTask({bool done = false}) {
    return Task(
      title: '每日喝水',
      type: TaskType.daily,
      startDate: DateTime(2026, 9, 1),
      dueDate: DateTime(2026, 9, 30),
      completed: false,
    );
  }

  testWidgets('daily：区间文案 + checkedOverride 驱动勾选/划线', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(TaskListTile(task: dailyTask(), checkedOverride: true)),
    );

    // 区间「起始~截止」文案。
    expect(find.textContaining('9月1日~9月30日'), findsOneWidget);
    // 勾选状态跟随当日打卡覆盖值。
    final Checkbox box = tester.widget<Checkbox>(find.byType(Checkbox));
    expect(box.value, isTrue);
    // 完成划线跟随覆盖值。
    final Text title = tester.widget<Text>(find.text('每日喝水'));
    expect(title.style?.decoration, TextDecoration.lineThrough);
  });

  testWidgets('daily：未打卡显示未勾选且无划线', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(TaskListTile(task: dailyTask(), checkedOverride: false)),
    );

    final Checkbox box = tester.widget<Checkbox>(find.byType(Checkbox));
    expect(box.value, isFalse);
    final Text title = tester.widget<Text>(find.text('每日喝水'));
    expect(title.style?.decoration, isNull);
  });

  testWidgets('daily：showCheckbox=false（列表页）不显示勾选框、不回调', (WidgetTester tester) async {
    bool toggled = false;
    await tester.pumpWidget(
      wrap(TaskListTile(
        task: dailyTask(),
        showCheckbox: false,
        onToggle: () => toggled = true,
      )),
    );

    expect(find.byType(Checkbox), findsNothing);
    expect(toggled, isFalse);
    // 区间文案仍展示。
    expect(find.textContaining('9月1日~9月30日'), findsOneWidget);
  });

  testWidgets('span：区间文案；completed 驱动勾选与划线', (WidgetTester tester) async {
    final Task task = Task(
      title: '暑期阅读',
      type: TaskType.span,
      startDate: DateTime(2026, 9, 1),
      dueDate: DateTime(2026, 9, 30),
      completed: true,
    );
    await tester.pumpWidget(wrap(TaskListTile(task: task)));

    expect(find.textContaining('9月1日~9月30日'), findsOneWidget);
    final Checkbox box = tester.widget<Checkbox>(find.byType(Checkbox));
    expect(box.value, isTrue);
  });

  testWidgets('scheduled：仍显示截止日期 + 时刻，不用区间', (WidgetTester tester) async {
    final Task task = Task(
      title: '看牙医',
      type: TaskType.scheduled,
      dueDate: DateTime(2026, 9, 5),
      dueTime: '09:30',
      completed: false,
    );
    await tester.pumpWidget(wrap(TaskListTile(task: task)));

    expect(find.textContaining('9月5日 09:30'), findsOneWidget);
    expect(find.textContaining('~'), findsNothing);
  });
}
