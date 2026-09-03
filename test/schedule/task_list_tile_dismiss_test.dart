import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/features/schedule/task_list_tile.dart';

/// 左滑删除 Dismissible 回归测试：确认弹窗「取消」→ 条目弹回原位仍显示、无
/// 报错；「删除」→ 条目从列表移除、无报错。父级负责在确认返回 true 后把
/// 条目从树中移除（真实页面由数据 provider 刷新驱动）。
void main() {
  testWidgets('左滑→取消：条目弹回原位、仍在列表、无报错', (WidgetTester tester) async {
    await tester.pumpWidget(_Harness(confirm: () async => false));
    final double originX = tester.getTopLeft(find.text('滑动任务')).dx;

    await tester.drag(find.text('滑动任务'), const Offset(-600, 0));
    await tester.pumpAndSettle();

    // 取消：条目未删、仍在列表，Dismissible 弹回原位（content 回到拖动前 x）。
    expect(find.text('滑动任务'), findsOneWidget);
    final double snappedX = tester.getTopLeft(find.text('滑动任务')).dx;
    expect(snappedX, originX);
    expect(tester.takeException(), isNull);

    // 模拟后续任意重建（如手动刷新 / 新建任务触发的 rebuild）不再报黄条。
    await tester.pumpWidget(_Harness(confirm: () async => false));
    await tester.pumpAndSettle();
    expect(find.text('滑动任务'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('左滑→删除：条目从列表移除、无报错', (WidgetTester tester) async {
    await tester.pumpWidget(_Harness(confirm: () async => true));

    await tester.drag(find.text('滑动任务'), const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(find.text('滑动任务'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

/// 宿主：确认返回 true 时把条目从树中移除（模拟真实页面的数据源刷新行为）。
class _Harness extends StatefulWidget {
  const _Harness({required this.confirm});

  final Future<bool> Function() confirm;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool _removed = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: _removed
            ? const SizedBox.shrink()
            : ListView(
                children: <Widget>[
                  TaskListTile(
                    task: _task(),
                    onConfirmDelete: () async {
                      final bool ok = await widget.confirm();
                      if (ok && mounted) {
                        setState(() => _removed = true);
                      }
                      return ok;
                    },
                  ),
                ],
              ),
      ),
    );
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
