import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/course.dart';
import '../../data/models/task.dart';
import '../timetable/format.dart';
import 'schedule_providers.dart';
import 'task_form_page.dart';
import 'task_rules.dart';

/// 任务详情页：通知点击「任务提醒」的深链目标。
///
/// 路由参数：[AppRoutes.taskDetail] 携带 `int` 任务主键；参数缺失时不展示。
/// 提供打卡 / 编辑 / 删除入口（编辑复用 [TaskFormPage]）。
class TaskDetailPage extends ConsumerWidget {
  const TaskDetailPage({super.key, this.taskId});

  /// 显式传入的任务 id（直接构造时使用）；命名路由深链走路由参数。
  final int? taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Object? args = ModalRoute.of(context)?.settings.arguments;
    final int? id = taskId ?? (args is int ? args : null);
    if (id == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('任务详情')),
        body: const Center(child: Text('缺少任务参数')),
      );
    }
    final AsyncValue<Task?> taskAsync = ref.watch(taskByIdProvider(id));
    return Scaffold(
      appBar: AppBar(title: const Text('任务详情')),
      body: taskAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('任务加载失败')),
        data: (Task? task) {
          if (task == null) {
            return const Center(child: Text('任务不存在或已删除'));
          }
          return _buildBody(context, ref, task);
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref, Task task) {
    final ThemeData theme = Theme.of(context);
    final bool overdue = isTaskOverdue(task);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                task.title,
                style: theme.textTheme.headlineSmall,
              ),
            ),
            if (task.completed)
              Icon(Icons.check_circle, color: theme.colorScheme.primary)
            else if (overdue)
              Icon(Icons.error_outline, color: theme.colorScheme.error),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _statusText(task, overdue),
          style: theme.textTheme.bodySmall?.copyWith(
            color: overdue
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        _detailCard(context, ref, task),
        const SizedBox(height: 16),
        if (task.description.isNotEmpty) ...[
          Text('描述', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Text(task.description, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
        ],
        FilledButton.icon(
          onPressed: () => _toggle(context, ref, task),
          icon: Icon(task.completed
              ? Icons.undo
              : Icons.check),
          label: Text(task.completed ? '取消打卡' : '标记完成'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _edit(context, ref, task),
          icon: const Icon(Icons.edit_outlined),
          label: const Text('编辑任务'),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => _delete(context, ref, task),
          icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
          label: Text('删除任务',
              style: TextStyle(color: theme.colorScheme.error)),
        ),
      ],
    );
  }

  Widget _detailCard(BuildContext context, WidgetRef ref, Task task) {
    final ThemeData theme = Theme.of(context);
    final String time = task.dueTime ?? '';
    final String dueText = formatFullDate(task.dueDate) +
        (time.isEmpty ? '' : ' $time');
    final String remindText = _remindText(task);

    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.event_outlined),
            title: const Text('类型'),
            trailing: Text(task.type.label,
                style: theme.textTheme.bodyMedium),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: const Text('优先级'),
            trailing: Text(task.priority.label,
                style: theme.textTheme.bodyMedium),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.schedule_outlined),
            title: const Text('截止'),
            trailing: Text(dueText, style: theme.textTheme.bodyMedium),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.book_outlined),
            title: const Text('关联课程'),
            trailing: _courseTrailing(context, ref, task),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('提醒'),
            trailing: Text(remindText, style: theme.textTheme.bodyMedium),
          ),
          if (task.completedAt != null) ...[
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: const Text('完成时间'),
              trailing: Text(
                formatFullDate(task.completedAt!),
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _courseTrailing(BuildContext context, WidgetRef ref, Task task) {
    final int? courseId = task.courseId;
    if (courseId == null) {
      return Text('未关联', style: Theme.of(context).textTheme.bodyMedium);
    }
    final AsyncValue<Course?> courseAsync = ref.watch(courseByIdProvider(courseId));
    return courseAsync.when(
      loading: () => const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      error: (_, _) => Text('课程',
          style: Theme.of(context).textTheme.bodyMedium),
      data: (Course? course) => Text(
        course?.name ?? '未知课程',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }

  String _statusText(Task task, bool overdue) {
    if (task.completed) {
      final String at =
          task.completedAt == null ? '' : ' · ${formatFullDate(task.completedAt!)}';
      return '已完成$at';
    }
    if (overdue) return '已逾期，待完成';
    return task.type == TaskType.scheduled ? '待打卡' : '待完成';
  }

  String _remindText(Task task) {
    if (task.remindOffsetMin == null) return '不提醒';
    final DateTime? at = task.remindDate ?? computeRemindAt(task);
    if (at == null) return '不提醒';
    final String atText =
        '${formatFullDate(at)} ${formatTimeOfDay(TimeOfDay(hour: at.hour, minute: at.minute))}';
    if (task.remindOffsetMin == -1) {
      return task.type == TaskType.todo ? '当天 8:00 提醒' : '准时（$atText）';
    }
    return '提前 ${task.remindOffsetMin} 分钟（$atText）';
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref, Task task) async {
    try {
      await toggleTaskCompleted(ref, task);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('操作失败，请稍后重试')),
        );
      }
    }
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, Task task) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => TaskFormPage(task: task)),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Task task) async {
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
      await deleteTask(ref, task.id!);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('删除失败，请稍后重试')),
        );
      }
      return;
    }
    if (context.mounted) Navigator.of(context).pop();
  }
}
