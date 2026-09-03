import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/features/schedule/task_list_tile.dart';

/// 左滑删除交互测试（自绘限位手势：拖到宽 1/3 顶住，松手位移 ≥ 阈值才触发）：
/// - 左滑到位松手 → 确认框出现 + 条目回原位仍在；
/// - 确认（删除）→ 条目随数据刷新移除、无报错；
/// - 取消 → 条目保留原位、无报错；
/// - 左滑不足 → 仅回弹不触发确认框。
///
/// 宿主 `_confirm` 模拟真实 confirmDeleteTask：弹确认框，确认后把条目从树中
/// 移除（真实页面由列表数据源刷新驱动）。测试默认画布宽 800（tile 宽 ~800：
/// 限位 ~266、触发阈值 ~133）。
void main() {
  testWidgets('左滑不足：仅回弹不触发确认框，条目保留无报错',
      (WidgetTester tester) async {
    await tester.pumpWidget(const _Harness());
    final double originX = tester.getTopLeft(find.text('滑动任务')).dx;

    // 滑 80px（远低于阈值 ~133）：松手只回弹，不弹确认框。
    await tester.drag(find.text('滑动任务'), const Offset(-80, 0));
    await tester.pumpAndSettle();

    expect(find.text('删除任务'), findsNothing);
    expect(find.text('滑动任务'), findsOneWidget);
    expect(tester.getTopLeft(find.text('滑动任务')).dx, originX);
    expect(tester.takeException(), isNull);
  });


  testWidgets('左滑→取消：弹回原位仍在 + 确认框出现 → 点取消条目保留无报错',
      (WidgetTester tester) async {
    await tester.pumpWidget(const _Harness());
    final double originX = tester.getTopLeft(find.text('滑动任务')).dx;

    await tester.drag(find.text('滑动任务'), const Offset(-600, 0));
    await tester.pumpAndSettle();

    // 触发后：条目仍在且回原位，确认框已弹出。
    expect(find.text('删除任务'), findsOneWidget);
    expect(find.text('滑动任务'), findsOneWidget);
    expect(tester.getTopLeft(find.text('滑动任务')).dx, originX);
    expect(tester.takeException(), isNull);

    // 点取消：条目保留原位，无报错，无 dismissed 残留黄条。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('删除任务'), findsNothing);
    expect(find.text('滑动任务'), findsOneWidget);
    expect(tester.getTopLeft(find.text('滑动任务')).dx, originX);
    expect(tester.takeException(), isNull);

    // 模拟后续任意重建（刷新 / 新建触发 rebuild）仍无报错。
    await tester.pumpWidget(const _Harness());
    await tester.pumpAndSettle();
    expect(find.text('滑动任务'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('左滑→删除：弹回 + 确认框 → 点删除条目随刷新移除无报错',
      (WidgetTester tester) async {
    await tester.pumpWidget(const _Harness());

    await tester.drag(find.text('滑动任务'), const Offset(-600, 0));
    await tester.pumpAndSettle();

    // 触发后确认框弹出、条目回原位。
    expect(find.text('删除任务'), findsOneWidget);
    expect(find.text('滑动任务'), findsOneWidget);

    // 点删除：条目随数据刷新从列表移除，无报错。
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除任务'), findsNothing);
    expect(find.text('滑动任务'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('先下后左的斜向拖动：列表滚动优先，tile 不动、不触发删除',
      (WidgetTester tester) async {
    await tester.pumpWidget(const _Harness());
    final double originX = tester.getTopLeft(find.text('滑动任务')).dx;

    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(find.text('滑动任务')));
    // 先明显纵向（纵向一旦过 slop，本 tile 的横向识别器应主动放弃）。
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    // 再向左滑：若识别器未放弃，会继续左移 tile 并误触发。
    for (int i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(-25, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('删除任务'), findsNothing);
    expect(tester.getTopLeft(find.text('滑动任务')).dx, originX);
    expect(tester.takeException(), isNull);
  });

  testWidgets('45° 斜向拖动：不触发删除、tile 不左移、无确认框',
      (WidgetTester tester) async {
    await tester.pumpWidget(const _Harness());
    final double originX = tester.getTopLeft(find.text('滑动任务')).dx;

    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(find.text('滑动任务')));
    // ~45° 左下对角线（dy≈dx）：横向分量不足主导 → 应让列表纵向滚动接管。
    for (int i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(-14, 14));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('删除任务'), findsNothing);
    expect(tester.getTopLeft(find.text('滑动任务')).dx, originX);
    expect(tester.takeException(), isNull);
  });
}

/// 宿主：`_confirm` 弹确认框；确认 → 把条目从树中移除并返回 true；取消 → 保留。
class _Harness extends StatefulWidget {
  const _Harness();

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool _removed = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext contentContext) {
            if (_removed) return const SizedBox.shrink();
            return ListView(
              children: <Widget>[
                TaskListTile(
                  task: _task(),
                  onConfirmDelete: () => _confirm(contentContext),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<bool> _confirm(BuildContext dialogHost) async {
    final bool? ok = await showDialog<bool>(
      context: dialogHost, // 须为 MaterialApp 之下的 context（有 Localizations）。
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除任务'),
        content: const Text('确定删除？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      // 模拟删除成功后列表数据源刷新 → 条目出树。
      setState(() => _removed = true);
    }
    return ok == true;
  }
}

Task _task() {
  return Task(
    title: '滑动任务',
    type: TaskType.todo,
    dueDate: DateTime.now(),
    completed: false,
  );
}
