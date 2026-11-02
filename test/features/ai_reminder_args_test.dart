import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/data/models/task.dart';
import 'package:plai/features/ai/ai_read_tools.dart';
import 'package:plai/features/ai/ai_write_tools.dart';
import 'package:plai/features/schedule/schedule_providers.dart';
import 'package:plai/features/timetable/timetable_providers.dart';
import 'package:plai/services/notifications/class_reminder_planner.dart';
import 'package:plai/services/notifications/notification_providers.dart';

import 'ai_page_test.dart'
    show FakeTaskRepository, FakeTimetableRepository, FakeScheduler;

/// 只记录调用、不触通知插件的调度器。
///
/// [FakeScheduler] 的 `scheduleTaskReminder` 是空实现，这里额外记下最后
/// 一次被调度的任务，断言「写库的提醒字段」与「实际交给调度器的任务」一致。
class _RecordingScheduler extends FakeScheduler {
  Task? lastScheduled;

  @override
  Future<void> scheduleTaskReminder(Task task) async {
    lastScheduled = task;
  }

  @override
  Future<void> rescheduleAll({List<ClassReminderPlan>? classPlans}) async {}

  @override
  Future<void> cancelAllRemindersFor({int? courseId, int? taskId}) async {}
}

/// create_task / update_task 的 schema（名字即 wire 上的函数名）。
AiWriteTool _tool(String name) =>
    aiWriteTools.firstWhere((AiWriteTool t) => t.name == name);

/// 在真实 ProviderContainer 里执行写工具（任务仓储用内存假实现）。
Future<String> _exec(
  ProviderContainer container,
  String toolName,
  Map<String, dynamic> args,
) {
  final AiWriteTool tool = _tool(toolName);
  return tool.execute(_RefOf(container), args);
}

/// 极薄的 WidgetRef 适配：写工具只用到 `ref.read` 与 `ref.invalidate`。
class _RefOf implements WidgetRef {
  _RefOf(this._c);

  final ProviderContainer _c;

  @override
  T read<T>(ProviderListenable<T> provider) => _c.read(provider);

  @override
  void invalidate(ProviderOrFamily provider) => _c.invalidate(provider);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('测试适配器不支持 ${invocation.memberName}');
}

void main() {
  group('AI 写工具：提醒参数的 schema 与校验', () {
    test('create_task / update_task 都暴露 remind_time 与 remind_at', () {
      for (final String name in <String>['create_task', 'update_task']) {
        final Map<String, dynamic> params = _tool(name).parameters;
        final Map<String, dynamic> props =
            params['properties'] as Map<String, dynamic>;
        expect(props.containsKey('remind_time'), isTrue, reason: name);
        expect(props.containsKey('remind_at'), isTrue, reason: name);
        // 提醒不是必填——没有提醒要求时模型不该被迫传。
        final List<dynamic> required =
            params['required'] as List<dynamic>? ?? const <dynamic>[];
        expect(required.contains('remind_time'), isFalse, reason: name);
        expect(required.contains('remind_at'), isFalse, reason: name);
      }
    });

    test('create_task：同时传两种提醒被拒（不会静默取其一）', () {
      final String? err = _tool('create_task').validate(<String, dynamic>{
        'title': '交作业',
        'due_date': '2099-01-01',
        'remind_time': '08:00',
        'remind_at': '2099-01-01 07:00',
      });
      expect(err, isNotNull);
      expect(err, contains('只能'));
    });

    test('create_task：remind_at 格式非法 / 已过期 都被拒', () {
      final String? badFormat = _tool('create_task').validate(<String, dynamic>{
        'title': '交作业',
        'due_date': '2099-01-01',
        'remind_at': '明天下午三点',
      });
      expect(badFormat, contains('格式无效'));

      final String? past = _tool('create_task').validate(<String, dynamic>{
        'title': '交作业',
        'due_date': '2099-01-01',
        'remind_at': '2020-01-01 08:00',
      });
      expect(past, contains('必须晚于现在'));
    });

    test('create_task：remind_time 仍是合法 HH:mm 才通过', () {
      expect(
        _tool('create_task').validate(<String, dynamic>{
          'title': '交作业',
          'due_date': '2099-01-01',
          'remind_time': '25:00',
        }),
        contains('HH:mm'),
      );
      expect(
        _tool('create_task').validate(<String, dynamic>{
          'title': '交作业',
          'due_date': '2099-01-01',
          'remind_time': '08:00',
        }),
        isNull,
      );
    });

    test('每日打卡（daily）不支持一次性提醒', () {
      final String? err = _tool('create_task').validate(<String, dynamic>{
        'title': '喝水',
        'type': 'daily',
        'due_date': '2099-01-01',
        'remind_at': '2099-01-01 08:00',
      });
      expect(err, contains('每天'));
    });

    test('update_task：空串是合法的「清除提醒」信号', () {
      expect(
        _tool('update_task')
            .validate(<String, dynamic>{'task_id': 1, 'remind_time': ''}),
        isNull,
      );
      expect(
        _tool('update_task')
            .validate(<String, dynamic>{'task_id': 1, 'remind_at': ''}),
        isNull,
      );
    });
  });

  group('AI 写工具：确认卡片文案', () {
    test('一次性提醒写成「X月X日 HH:mm 提醒一次」', () {
      final String desc = _tool('create_task').describeQuick!(<String, dynamic>{
        'title': '交作业',
        'due_date': '2099-01-01',
        'remind_at': '2099-01-02 14:30',
      });
      expect(desc, contains('2099年1月2日 14:30 提醒一次'));
    });

    test('每天提醒仍是「每天 HH:mm 提醒」', () {
      final String desc = _tool('create_task').describeQuick!(<String, dynamic>{
        'title': '交作业',
        'due_date': '2099-01-01',
        'remind_time': '08:00',
      });
      expect(desc, contains('每天 08:00 提醒'));
    });

    test('没有提醒参数时不出现任何提醒字样', () {
      final String desc = _tool('create_task').describeQuick!(<String, dynamic>{
        'title': '交作业',
        'due_date': '2099-01-01',
      });
      expect(desc, isNot(contains('提醒')));
    });
  });

  group('AI 写工具：落库与调度', () {
    late FakeTaskRepository taskRepo;
    late _RecordingScheduler scheduler;
    late ProviderContainer container;

    setUp(() {
      taskRepo = FakeTaskRepository();
      scheduler = _RecordingScheduler();
      container = ProviderContainer(
        overrides: [
          taskRepositoryProvider.overrideWithValue(taskRepo),
          timetableRepositoryProvider.overrideWithValue(
            FakeTimetableRepository(),
          ),
          notificationSchedulerProvider.overrideWithValue(scheduler),
        ],
      );
      addTearDown(container.dispose);
    });

    test('create_task + remind_at → 落成 once，且不动 daily_remind_time', () async {
      final String raw = await _exec(
        container,
        'create_task',
        <String, dynamic>{
          'title': '交高数作业',
          'due_date': '2099-01-01',
          'remind_at': '2099-01-02 14:30',
        },
      );
      expect(jsonDecode(raw)['status'], 'created');

      final Task saved = (await taskRepo.getTasks()).single;
      expect(saved.reminderRepeat, ReminderRepeat.once);
      expect(saved.remindOnceAt, DateTime(2099, 1, 2, 14, 30));
      expect(saved.dailyRemindTime, isNull);
      // 交给调度器的就是这份数据（调度器按 reminderRepeat 走一次性分支）。
      expect(
        scheduler.lastScheduled?.remindOnceAt,
        DateTime(2099, 1, 2, 14, 30),
      );
    });

    test('create_task + remind_time → 落成 daily（老行为不变）', () async {
      await _exec(container, 'create_task', <String, dynamic>{
        'title': '交高数作业',
        'due_date': '2099-01-01',
        'remind_time': '08:00',
      });
      final Task saved = (await taskRepo.getTasks()).single;
      expect(saved.dailyRemindTime, '08:00');
      expect(saved.reminderRepeat, ReminderRepeat.daily);
      expect(saved.remindOnceAt, isNull);
    });

    test('create_task 不带提醒参数 → 三个字段全空', () async {
      await _exec(container, 'create_task', <String, dynamic>{
        'title': '交高数作业',
        'due_date': '2099-01-01',
      });
      final Task saved = (await taskRepo.getTasks()).single;
      expect(saved.dailyRemindTime, isNull);
      expect(saved.reminderRepeat, isNull);
      expect(saved.remindOnceAt, isNull);
    });

    test('update_task：每天 → 不重复（切换模式时清掉另一个字段）', () async {
      taskRepo.seed(
        Task(
          id: 1,
          title: '交高数作业',
          type: TaskType.todo,
          dueDate: DateTime(2099, 1, 1),
          dailyRemindTime: '08:00',
          reminderRepeat: ReminderRepeat.daily,
        ),
      );

      await _exec(container, 'update_task', <String, dynamic>{
        'task_id': 1,
        'remind_at': '2099-01-02 14:30',
      });

      final Task saved = (await taskRepo.getTaskById(1))!;
      expect(saved.reminderRepeat, ReminderRepeat.once);
      expect(saved.remindOnceAt, DateTime(2099, 1, 2, 14, 30));
      // 关键：切换成一次性后必须把每日时刻清掉，否则调度器仍会按每天重复。
      expect(saved.dailyRemindTime, isNull);
    });

    test('update_task：不重复 → 每天（反向切换同样清干净）', () async {
      taskRepo.seed(
        Task(
          id: 1,
          title: '交高数作业',
          type: TaskType.todo,
          dueDate: DateTime(2099, 1, 1),
          reminderRepeat: ReminderRepeat.once,
          remindOnceAt: DateTime(2099, 1, 2, 14, 30),
        ),
      );

      await _exec(container, 'update_task', <String, dynamic>{
        'task_id': 1,
        'remind_time': '07:50',
      });

      final Task saved = (await taskRepo.getTaskById(1))!;
      expect(saved.reminderRepeat, ReminderRepeat.daily);
      expect(saved.dailyRemindTime, '07:50');
      expect(saved.remindOnceAt, isNull);
    });

    test('update_task：传空串能真正清除提醒（历史 bug 回归）', () async {
      // 旧实现 `copyWith(dailyRemindTime: null)` 的 null 语义是「保持原值」，
      // 清除从未生效；这里守住「传空串 → 三个字段都清空」。
      taskRepo.seed(
        Task(
          id: 1,
          title: '交高数作业',
          type: TaskType.todo,
          dueDate: DateTime(2099, 1, 1),
          dailyRemindTime: '08:00',
          reminderRepeat: ReminderRepeat.daily,
        ),
      );

      await _exec(container, 'update_task', <String, dynamic>{
        'task_id': 1,
        'remind_time': '',
      });

      final Task saved = (await taskRepo.getTaskById(1))!;
      expect(saved.dailyRemindTime, isNull);
      expect(saved.reminderRepeat, isNull);
      expect(saved.remindOnceAt, isNull);
    });

    test('update_task：清除一次性提醒后 daily 字段也不会残留', () async {
      taskRepo.seed(
        Task(
          id: 1,
          title: '交高数作业',
          type: TaskType.todo,
          dueDate: DateTime(2099, 1, 1),
          reminderRepeat: ReminderRepeat.once,
          remindOnceAt: DateTime(2099, 1, 2, 14, 30),
        ),
      );

      await _exec(container, 'update_task', <String, dynamic>{
        'task_id': 1,
        'remind_at': '',
      });

      final Task saved = (await taskRepo.getTaskById(1))!;
      expect(saved.reminderRepeat, isNull);
      expect(saved.remindOnceAt, isNull);
      expect(saved.dailyRemindTime, isNull);
    });

    test('update_task：不传提醒参数时原提醒保持不变', () async {
      taskRepo.seed(
        Task(
          id: 1,
          title: '交高数作业',
          type: TaskType.todo,
          dueDate: DateTime(2099, 1, 1),
          dailyRemindTime: '08:00',
          reminderRepeat: ReminderRepeat.daily,
        ),
      );

      await _exec(container, 'update_task', <String, dynamic>{
        'task_id': 1,
        'title': '交高数作业（改）',
      });

      final Task saved = (await taskRepo.getTaskById(1))!;
      expect(saved.title, '交高数作业（改）');
      expect(saved.dailyRemindTime, '08:00');
      expect(saved.reminderRepeat, ReminderRepeat.daily);
    });
  });

  group('AI 读工具：get_tasks 回显提醒现状', () {
    test('三种提醒模式各回显一句，与详情页口径一致', () async {
      final FakeTaskRepository taskRepo = FakeTaskRepository();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          taskRepositoryProvider.overrideWithValue(taskRepo),
          timetableRepositoryProvider.overrideWithValue(
            FakeTimetableRepository(),
          ),
          notificationSchedulerProvider.overrideWithValue(FakeScheduler()),
        ],
      );
      addTearDown(container.dispose);

      final DateTime due = DateTime(2099, 1, 1);
      taskRepo.seed(
        Task(
          id: 1,
          title: '每天提醒的',
          type: TaskType.todo,
          dueDate: due,
          dailyRemindTime: '08:00',
          reminderRepeat: ReminderRepeat.daily,
        ),
      );
      taskRepo.seed(
        Task(
          id: 2,
          title: '一次提醒的',
          type: TaskType.todo,
          dueDate: due,
          reminderRepeat: ReminderRepeat.once,
          remindOnceAt: DateTime(2099, 1, 2, 14, 30),
        ),
      );
      taskRepo.seed(
        Task(id: 3, title: '不提醒的', type: TaskType.todo, dueDate: due),
      );

      final AiReadTool tool = aiReadTools.firstWhere(
        (AiReadTool t) => t.name == 'query',
      );
      final String raw = await tool.execute(_RefOf(container), <String, dynamic>{
        'action': 'tasks',
        'filter': 'all',
      });
      final List<dynamic> rows = (jsonDecode(raw)['tasks'] as List<dynamic>);
      final Map<int, Map<String, dynamic>> byId = <int, Map<String, dynamic>>{
        for (final dynamic r in rows)
          (r as Map<String, dynamic>)['id'] as int: r,
      };

      expect(byId[1]!['remind'], '每天 08:00');
      expect(byId[2]!['remind'], '2099-01-02 14:30 提醒一次');
      // 没有提醒的任务不带该键（不写 null，模型不会误判成「有提醒」）。
      expect(byId[3]!.containsKey('remind'), isFalse);
    });
  });
}

