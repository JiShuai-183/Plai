import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/task.dart';

import 'test_helpers.dart';

void main() {
  late TestData data;

  setUp(() async {
    data = await TestData.create();
  });

  tearDown(() async {
    await data.db.close();
  });

  test('Task CRUD 往返一致（含所有字段）', () async {
    final repo = data.tasks;
    final task = Task(
      title: '交高数作业',
      description: '第 3 章习题',
      type: TaskType.todo,
      dueDate: DateTime(2026, 10, 1),
      dueTime: '23:59',
      priority: Priority.important,
      remindOffsetMin: 30,
      remindDate: DateTime(2026, 10, 1, 23, 29),
    );
    final id = await repo.insertTask(task);

    final fetched = await repo.getTaskById(id);
    expect(fetched, task.copyWith(id: id));

    await repo.updateTask(task.copyWith(id: id, completed: true, completedAt: DateTime(2026, 10, 1, 20)));
    final updated = await repo.getTaskById(id);
    expect(updated!.completed, isTrue);
    expect(updated.completedAt, isNotNull);

    expect(await repo.deleteTask(id), 1);
    expect(await repo.getTaskById(id), isNull);
  });

  test('insertTask 未指定 createdAt 时自动填当前时间', () async {
    final repo = data.tasks;
    final id = await repo.insertTask(
      Task(title: '背单词', type: TaskType.todo, dueDate: DateTime(2026, 9, 5)),
    );
    final fetched = await repo.getTaskById(id);
    expect(fetched!.createdAt, isNotNull);
  });

  test('getTasks 支持类型/完成/日期范围过滤', () async {
    final repo = data.tasks;
    await repo.insertTask(Task(title: '会议', type: TaskType.scheduled, dueDate: DateTime(2026, 9, 1)));
    await repo.insertTask(Task(title: '作业A', type: TaskType.todo, dueDate: DateTime(2026, 9, 2)));
    await repo.insertTask(Task(title: '作业B', type: TaskType.todo, dueDate: DateTime(2026, 9, 5)));

    expect(await repo.getTasks(type: TaskType.todo), hasLength(2));
    expect(await repo.getTasks(type: TaskType.scheduled), hasLength(1));
    expect(await repo.getTasks(completed: false), hasLength(3));
    expect(
      await repo.getTasks(from: DateTime(2026, 9, 3), to: DateTime(2026, 9, 5)),
      hasLength(1),
    );
  });

  test('setCompleted 标记完成并记录/清空完成时间', () async {
    final repo = data.tasks;
    final id = await repo.insertTask(
      Task(title: '项目截止', type: TaskType.todo, dueDate: DateTime(2026, 9, 10)),
    );

    expect(await repo.setCompleted(id, true), 1);
    var task = await repo.getTaskById(id);
    expect(task!.completed, isTrue);
    expect(task.completedAt, isNotNull);

    expect(await repo.setCompleted(id, false), 1);
    task = await repo.getTaskById(id);
    expect(task!.completed, isFalse);
    expect(task.completedAt, isNull);
  });
}
