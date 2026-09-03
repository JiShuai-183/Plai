import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/task.dart';
import '../../routes/app_routes.dart';
import 'schedule_providers.dart';

/// 打开任务详情（命名路由；通知深链与列表点击共用同一入口）。
Future<void> openTaskDetail(BuildContext context, Task task) {
  final int? id = task.id;
  if (id == null) return Future.value();
  return Navigator.of(context).pushNamed(AppRoutes.taskDetail, arguments: id);
}

/// 删除任务前二次确认；确认后删除并取消提醒，等列表数据源刷新完成。
///
/// 供 `TaskListTile.onConfirmDelete`（Dismissible.confirmDismiss）使用：
/// - true：用户确认且删除成功，条目已从数据/重建树移除，放行滑出；
/// - false：用户取消或删除失败（弹回原位，不误删 / 不残留已滑出条目）。
Future<bool> confirmDeleteTask(
    BuildContext context, WidgetRef ref, Task task) async {
  final int? id = task.id;
  if (id == null) return false;
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('删除任务'),
      content: Text('确定删除「${task.title}」吗？此操作不可恢复。'),
      actions: [
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
  if (ok != true) return false; // 取消：不删，Dismissible 弹回原位。
  try {
    await deleteTask(ref, id);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('删除失败，请稍后重试')),
      );
    }
    return false; // 删除失败：不滑出，条目保留。
  }
  // 删除已成功：等列表根数据源刷新完成，确保条目已不在重建树中再放行滑出，
  // 避免 Dismissible 以已滑出状态残留。刷新异常不影响删除结果，静默放行。
  try {
    await ref.read(tasksProvider.future);
  } catch (_) {
    // ignore：删除已成功；页面侧 provider 自会重建兜底移除条目。
  }
  return true;
}
