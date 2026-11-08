import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/features/ai/ai_read_tools.dart';
import 'package:plai/features/ai/ai_tool_context.dart';
import 'package:plai/features/ai/ai_write_tools.dart';
import 'package:plai/features/schedule/schedule_providers.dart';
import 'package:plai/features/timetable/timetable_providers.dart';
import 'package:plai/services/notifications/notification_providers.dart';

import 'ai_page_test.dart'
    show FakeTaskRepository, FakeTimetableRepository, FakeScheduler;

void main() {
  late FakeTaskRepository repo;
  late ProviderContainer container;
  late AiToolContext context;
  final tool = findAiWriteTool('save_task')!;
  setUp(() {
    repo = FakeTaskRepository();
    container = ProviderContainer(
      overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        timetableRepositoryProvider.overrideWithValue(
          FakeTimetableRepository(),
        ),
        notificationSchedulerProvider.overrideWithValue(FakeScheduler()),
      ],
    );
    context = AiToolContext(
      read: container.read,
      invalidate: container.invalidate,
    );
    addTearDown(container.dispose);
  });
  test('无期限待办和长期打卡真实保存，不丢每日提醒', () async {
    for (final args in [
      {'action': 'create', 'title': '买电池'},
      {'action': 'create', 'title': '每天背单词', 'remind_time': '08:00'},
    ]) {
      expect(tool.validate(args), isNull);
      expect(
        jsonDecode(await tool.execute(context, args))['status'],
        'created',
      );
    }
    final tasks = await repo.getTasks();
    expect(tasks.first.type, TaskType.todo);
    expect(tasks.first.dueDate, isNull);
    final daily = tasks.last;
    expect(daily.type, TaskType.daily);
    expect(daily.dueDate, isNull);
    final now = DateTime.now();
    expect(daily.startDate, DateTime(now.year, now.month, now.day));
    expect(daily.dailyRemindTime, '08:00');
  });
  test('跨期默认今天开始，保留截止时刻和照片，清除截止只允许可无期类型', () async {
    final args = {
      'action': 'create',
      'title': '交报告',
      'due_date': '2099-01-05',
      'due_time': '22:30',
    };
    expect(tool.validate(args), isNull);
    await tool.execute(context, args);
    final span = (await repo.getTasks()).single;
    expect(span.type, TaskType.span);
    expect(span.startDate, isNotNull);
    expect(span.dueTime, '22:30');
    final result = jsonDecode(
      await tool.execute(context, {
        'action': 'update',
        'task_id': span.id,
        'due_date': null,
      }),
    );
    expect(result['status'], 'error');
    repo.seed(
      Task(
        id: 99,
        title: '待办',
        type: TaskType.todo,
        dueDate: DateTime(2099),
        imagePaths: const ['/old.png'],
        dailyRemindTime: '09:00',
        reminderRepeat: ReminderRepeat.daily,
      ),
    );
    await tool.execute(context, {
      'action': 'update',
      'task_id': 99,
      'due_date': null,
    });
    final saved = (await repo.getTaskById(99))!;
    expect(saved.dueDate, isNull);
    expect(saved.imagePaths, ['/old.png']);
    expect(saved.dailyRemindTime, '09:00');
  });
  test('无期不误报逾期，未来打卡不进入今天查询', () async {
    repo.seed(Task(id: 1, title: '无期', type: TaskType.todo));
    repo.seed(
      Task(
        id: 2,
        title: '未来打卡',
        type: TaskType.daily,
        startDate: DateTime(2099),
      ),
    );
    repo.seed(
      Task(
        id: 3,
        title: '长期打卡',
        type: TaskType.daily,
        startDate: DateTime(2020),
      ),
    );
    final query = findAiReadTool('query')!;
    final overdue = jsonDecode(
      await query.execute(context, {'action': 'tasks', 'filter': 'overdue'}),
    );
    expect(overdue['tasks'], isEmpty);
    final today = jsonDecode(
      await query.execute(context, {'action': 'tasks', 'filter': 'today'}),
    );
    expect((today['tasks'] as List).map((t) => t['title']), ['长期打卡']);
  });
  test('拒绝反向区间及非法日期时刻', () {
    for (final extra in [
      {'type': 'daily', 'start_date': '2099-01-05', 'due_date': '2099-01-01'},
      {'due_date': '2099-02-31'},
      {'due_date': '2099-01-01', 'due_time': '24:99'},
    ]) {
      expect(
        tool.validate({'action': 'create', 'title': '测试', ...extra}),
        isNotNull,
      );
    }
  });
}
