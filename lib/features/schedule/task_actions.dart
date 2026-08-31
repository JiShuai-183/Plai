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

/// 删除任务前二次确认；确认后删除并取消提醒。
Future<void> confirmDeleteTask(
    BuildContext context, WidgetRef ref, Task task) async {
  final int? id = task.id;
  if (id == null) return;
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const Text('删除任务'),
      content: Text('确定删除「${task.title}」吗？此操作不可恢复。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    await deleteTask(ref, id);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('删除失败，请稍后重试')),
      );
    }
  }
}
