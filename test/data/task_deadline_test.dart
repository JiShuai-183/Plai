import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/backup/backup_service.dart';
import 'package:plai/data/models/task.dart';

import 'test_helpers.dart';

void main() {
  test('无期限模型往返与显式清空截止日期，省略则保留', () {
    final task = Task(title: '待办', type: TaskType.todo);
    expect(Task.fromDbMap(task.toDbMap()), task);
    expect(Task.fromJson(task.toJson()), task);
    expect(task.toDbMap()['due_date'], isNull);
    expect(task.toJson()['dueDate'], isNull);
    final dated = task.copyWith(dueDate: DateTime(2026, 11, 8));
    expect(dated.copyWith(title: '改标题').dueDate, dated.dueDate);
    expect(dated.copyWith(dueDate: null).dueDate, isNull);
    expect(task.toString(), contains('dueDate: null'));
  });

  test('无期限待办与长期daily可CRUD；无日期排最后且日期过滤排除', () async {
    final data = await TestData.create();
    try {
      final repo = data.tasks;
      final todoId = await repo.insertTask(
        Task(title: '无期限', type: TaskType.todo),
      );
      final dailyId = await repo.insertTask(
        Task(
          title: '长期打卡',
          type: TaskType.daily,
          startDate: DateTime(2026, 11, 8),
        ),
      );
      final datedId = await repo.insertTask(
        Task(
          title: '有日期',
          type: TaskType.span,
          dueDate: DateTime(2026, 11, 10),
        ),
      );
      expect((await repo.getTasks()).map((t) => t.id), [
        datedId,
        todoId,
        dailyId,
      ]);
      expect(
        (await repo.getTasks(from: DateTime(2026, 11, 1))).map((t) => t.id),
        [datedId],
      );
      expect(
        (await repo.getTasks(to: DateTime(2026, 11, 30))).map((t) => t.id),
        [datedId],
      );
      await repo.markDailyCompleted(dailyId, DateTime(2026, 11, 8));
      expect(
        await repo.isDailyCompleted(dailyId, DateTime(2026, 11, 8)),
        isTrue,
      );
      await repo.updateTask(
        (await repo.getTaskById(datedId))!.copyWith(dueDate: null),
      );
      expect((await repo.getTaskById(datedId))!.dueDate, isNull);
      await repo.setCompleted(todoId, true);
      expect((await repo.getTaskById(todoId))!.completed, isTrue);
      await repo.deleteTask(dailyId);
      expect(await repo.dailyLogsFor(dailyId), isEmpty);
    } finally {
      await data.db.close();
    }
  });

  test('V3备份无期限往返、null日期去重，保持本机任务', () async {
    final source = await TestData.create();
    final target = await TestData.create();
    BackupService service(TestData d) => BackupService(
      db: d.db,
      timetable: d.timetable,
      tasks: d.tasks,
      settings: d.settings,
    );
    try {
      await source.tasks.insertTask(
        Task(title: '同名', type: TaskType.todo, description: '备份'),
      );
      await source.tasks.insertTask(
        Task(
          title: '长期',
          type: TaskType.daily,
          startDate: DateTime(2026, 11, 8),
        ),
      );
      final json = await service(source).exportToJson();
      expect(json['version'], 3);
      await service(target).restore(json, strategy: RestoreStrategy.overwrite);
      expect(
        (await target.tasks.getTasks()).every((t) => t.dueDate == null),
        isTrue,
      );
      final local = (await target.tasks.getTasks()).first;
      await target.tasks.updateTask(local.copyWith(description: '本机'));
      await target.tasks.insertTask(
        Task(title: '同名', type: TaskType.todo, dueDate: DateTime(2026, 11, 9)),
      );
      await service(target).restore(json, strategy: RestoreStrategy.merge);
      final tasks = await target.tasks.getTasks();
      expect(tasks, hasLength(3));
      expect(tasks.singleWhere((t) => t.id == local.id).description, '本机');
    } finally {
      await source.db.close();
      await target.db.close();
    }
  });
}
