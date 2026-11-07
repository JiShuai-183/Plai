import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:plai/features/ai/ai_tool_context.dart';
import 'package:plai/features/ai/ai_write_tools.dart';
import 'package:plai/features/schedule/schedule_providers.dart';
import 'package:plai/services/notifications/notification_providers.dart';

class _Tasks implements ITaskRepository {
  _Tasks(this.task);
  Task task;

  @override
  Future<Task?> getTaskById(int id) async => task.id == id ? task : null;

  @override
  Future<int> updateTask(Task value) async {
    task = value;
    return 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('已有的 AI 文字和提醒修改保留手动附加的照片', () async {
    final repository = _Tasks(
      Task(
        id: 1,
        title: '交作业',
        type: TaskType.todo,
        dueDate: DateTime(2026, 11, 20),
        imagePaths: ['/managed/task_photos/homework.png'],
      ),
    );
    final container = ProviderContainer(
      overrides: [
        taskRepositoryProvider.overrideWithValue(repository),
        notificationSchedulerProvider.overrideWith(
          (ref) => throw StateError('测试不初始化通知'),
        ),
      ],
    );
    addTearDown(container.dispose);
    final context = AiToolContext(
      read: container.read,
      invalidate: container.invalidate,
    );
    final result = jsonDecode(
      await findAiWriteTool('save_task')!.execute(context, {
        'action': 'update',
        'task_id': 1,
        'title': '交数学作业',
        'description': '第二章',
        'remind_time': '20:00',
      }),
    ) as Map<String, dynamic>;
    expect(result['status'], 'updated');
    expect(repository.task.title, '交数学作业');
    expect(repository.task.description, '第二章');
    expect(repository.task.dailyRemindTime, '20:00');
    expect(repository.task.imagePaths, ['/managed/task_photos/homework.png']);
    expect(
      findAiWriteTool('save_task')!.parameters['properties'],
      isNot(contains('imagePaths')),
    );
  });
}
