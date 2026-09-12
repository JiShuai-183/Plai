import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/features/schedule/task_list_tile.dart';

/// 完成横线扫描交互测试：
/// - 未完成→完成：立即本地划线（横线从左往右扫），**动画播完才**提交 onToggle；
/// - 已完成→取消：立即恢复、不播反向动画、立即提交；
/// - 已完成的行首次渲染即为划好的横线，不播动画；
/// - 动画期间重复点击只提交一次（防重入）；
/// - showCheckbox=false 行为不受影响。
void main() {
  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: ListView(children: [child])));

  Task todoTask({bool completed = false}) => Task(
        title: '写作业',
        type: TaskType.todo,
        dueDate: DateTime(2026, 9, 20),
        completed: completed,
      );

  /// 当前横线扫描进度 = 上层裁剪 Align 的 widthFactor（0=无横线，1=划满）。
  double sweepFactor(WidgetTester tester) {
    final Finder align = find.ancestor(
      of: find.byKey(TaskListTile.titleSweepKey),
      matching: find.byType(Align),
    );
    return tester.widget<Align>(align.first).widthFactor!;
  }

  testWidgets('未完成→点复选框：立即起线，越过动画时长后才提交',
      (WidgetTester tester) async {
    int toggles = 0;
    await tester.pumpWidget(wrap(TaskListTile(
      task: todoTask(),
      onToggle: () => toggles++,
    )));

    expect(find.byKey(TaskListTile.titleSweepKey), findsNothing);
    final Checkbox box = tester.widget<Checkbox>(find.byType(Checkbox));
    expect(box.value, isFalse);

    await tester.tap(find.byType(Checkbox));
    await tester.pump(); // 处理点击 + 本地 setState
    await tester.pump(const Duration(milliseconds: 100)); // 动画进行中

    // 立即出现横线且未划满；动画未结束，尚未提交。
    expect(find.byKey(TaskListTile.titleSweepKey), findsOneWidget);
    expect(sweepFactor(tester), greaterThan(0.0));
    expect(sweepFactor(tester), lessThan(1.0));
    expect(toggles, 0);

    // 越过剩余时长（累计 300ms > 250ms）：动画播完才提交，横线划满。
    await tester.pump(const Duration(milliseconds: 200));
    expect(toggles, 1);
    expect(sweepFactor(tester), 1.0);
  });

  testWidgets('提交时机：点击当帧与动画中都不提交，动画完成后才调 onToggle',
      (WidgetTester tester) async {
    final List<String> log = <String>[];
    await tester.pumpWidget(wrap(TaskListTile(
      task: todoTask(),
      onToggle: () => log.add('toggle'),
    )));

    await tester.tap(find.byType(Checkbox));
    await tester.pump(); // 点击当帧
    expect(log, isEmpty);

    await tester.pump(const Duration(milliseconds: 200)); // 仍在动画中（<250）
    expect(log, isEmpty);

    await tester.pump(const Duration(milliseconds: 60)); // 越过 250
    expect(log, <String>['toggle']);
  });

  testWidgets('已完成的行首次渲染：横线即满宽、不播动画', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(TaskListTile(
      task: todoTask(completed: true),
      onToggle: () {},
    )));

    // 首帧即满宽：若走 0→1 动画，首帧应接近 0。
    expect(find.byKey(TaskListTile.titleSweepKey), findsOneWidget);
    expect(sweepFactor(tester), 1.0);

    // 再推一帧仍是满宽（无过渡）。
    await tester.pump(const Duration(milliseconds: 1));
    expect(sweepFactor(tester), 1.0);

    // 同状态重建一次也不重播动画。
    await tester.pumpWidget(wrap(TaskListTile(
      task: todoTask(completed: true),
      onToggle: () {},
    )));
    expect(sweepFactor(tester), 1.0);
  });

  testWidgets('已完成→取消：立即恢复无反向动画，onToggle 立即调用',
      (WidgetTester tester) async {
    int toggles = 0;
    await tester.pumpWidget(wrap(TaskListTile(
      task: todoTask(completed: true),
      onToggle: () => toggles++,
    )));
    expect(sweepFactor(tester), 1.0);

    await tester.tap(find.byType(Checkbox));
    await tester.pump(); // 点击当帧

    expect(toggles, 1); // 立即提交
    expect(find.byKey(TaskListTile.titleSweepKey), findsNothing); // 立即无横线
    final Checkbox box = tester.widget<Checkbox>(find.byType(Checkbox));
    expect(box.value, isFalse);

    // 无反向动画：后续帧横线不会重新出现。
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(TaskListTile.titleSweepKey), findsNothing);
  });

  testWidgets('防重入：动画期间重复点击，onToggle 只调用一次',
      (WidgetTester tester) async {
    int toggles = 0;
    await tester.pumpWidget(wrap(TaskListTile(
      task: todoTask(),
      onToggle: () => toggles++,
    )));

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100)); // 动画中
    await tester.tap(find.byType(Checkbox)); // 重复点击 → 忽略
    await tester.pump();
    await tester.tap(find.byType(Checkbox)); // 再点 → 忽略
    await tester.pump(const Duration(milliseconds: 100));
    expect(toggles, 0); // 动画未结束，仍未提交

    await tester.pump(const Duration(milliseconds: 60)); // 越过 250
    expect(toggles, 1); // 全程只提交一次
  });

  testWidgets('动画进行中外部重建（仍是未提交的旧值）不把横线回退',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrap(TaskListTile(
      task: todoTask(),
      onToggle: () {},
    )));
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100)); // 动画中
    expect(sweepFactor(tester), greaterThan(0.0));

    // 外部重建（task 仍 completed=false）：本 tile 发起、动画未结束 → 不回退。
    await tester.pumpWidget(wrap(TaskListTile(
      task: todoTask(),
      onToggle: () {},
    )));
    expect(find.byKey(TaskListTile.titleSweepKey), findsOneWidget);
    expect(sweepFactor(tester), greaterThan(0.0));
  });

  testWidgets('提交失败（外部仍为未完成）：动画后横线消失', (WidgetTester tester) async {
    await tester.pumpWidget(const _SubmitFailHost());

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100)); // 动画中
    expect(find.byKey(TaskListTile.titleSweepKey), findsOneWidget);

    // 动画播完 → onToggle → 外部仍 completed=false（模拟落库失败）→ 横线消失。
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.byKey(TaskListTile.titleSweepKey), findsNothing);
    expect(find.text('写作业'), findsOneWidget);
  });

  testWidgets('showCheckbox=false：无勾选框、无扫描层，仍随完成态显示横线',
      (WidgetTester tester) async {
    int toggles = 0;
    await tester.pumpWidget(wrap(TaskListTile(
      task: todoTask(),
      showCheckbox: false,
      onToggle: () => toggles++,
    )));
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byKey(TaskListTile.titleSweepKey), findsNothing);
    expect(toggles, 0);

    // 已完成 + 不显勾选框：横线仍直接满宽。
    await tester.pumpWidget(wrap(TaskListTile(
      task: todoTask(completed: true),
      showCheckbox: false,
      onToggle: () => toggles++,
    )));
    expect(find.byType(Checkbox), findsNothing);
    expect(sweepFactor(tester), 1.0);
  });
}

/// 模拟「提交失败」：onToggle 后外部重建，但 task.completed 仍为 false。
class _SubmitFailHost extends StatefulWidget {
  const _SubmitFailHost();

  @override
  State<_SubmitFailHost> createState() => _SubmitFailHostState();
}

class _SubmitFailHostState extends State<_SubmitFailHost> {
  int toggles = 0;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: ListView(
          children: <Widget>[
            TaskListTile(
              task: Task(
                title: '写作业',
                type: TaskType.todo,
                dueDate: DateTime(2026, 9, 20),
                completed: false,
              ),
              onToggle: () => setState(() => toggles++), // 状态不翻转 = 提交失败
            ),
          ],
        ),
      ),
    );
  }
}
