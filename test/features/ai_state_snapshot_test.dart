import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/data/models/task.dart';
import 'package:plai/features/ai/ai_providers.dart';
import 'package:plai/features/ai/ai_read_tools.dart';
import 'package:plai/features/ai/ai_tool_context.dart';
import 'package:plai/features/schedule/schedule_providers.dart';
import 'package:plai/features/timetable/timetable_providers.dart';

import 'ai_page_test.dart' show FakeTaskRepository, FakeTimetableRepository;

/// 极薄的 WidgetRef 适配：只读工具与快照只用到 `ref.read`。
class _RefOf implements AiToolContext {
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
  group('AI 状态快照（方案 B）', () {
    late FakeTaskRepository taskRepo;
    late ProviderContainer container;

    setUp(() {
      taskRepo = FakeTaskRepository();
      container = ProviderContainer(
        overrides: [
          taskRepositoryProvider.overrideWithValue(taskRepo),
          timetableRepositoryProvider.overrideWithValue(
            FakeTimetableRepository(),
          ),
        ],
      );
      addTearDown(container.dispose);
    });

    test('空数据：快照仍带日期与「没有课 / 没有未完成日程」', () async {
      final String snap = await buildAppStateSnapshot(_RefOf(container));
      expect(snap, contains('日期：'));
      expect(snap, contains('今天没有课'));
      expect(snap, contains('没有未完成的日程'));
    });

    test('带未完成任务：输出 id / 标题 / 截止日 / 提醒现状', () async {
      final DateTime now = DateTime.now();
      final DateTime today = DateTime(now.year, now.month, now.day);
      taskRepo.seed(
        Task(
          id: 7,
          title: '交高数作业',
          type: TaskType.todo,
          dueDate: today,
          dailyRemindTime: '08:00',
          reminderRepeat: ReminderRepeat.daily,
        ),
      );
      taskRepo.seed(
        Task(
          id: 8,
          title: '写实验报告',
          type: TaskType.todo,
          dueDate: today.add(const Duration(days: 3)),
        ),
      );
      // 已完成的不该出现。
      taskRepo.seed(
        Task(
          id: 9,
          title: '已经做完的事',
          type: TaskType.todo,
          dueDate: today,
          completed: true,
        ),
      );

      final String snap = await buildAppStateSnapshot(_RefOf(container));
      expect(snap, contains('#7 交高数作业'));
      expect(snap, contains('提醒：每天 08:00'));
      expect(snap, contains('#8 写实验报告'));
      expect(snap, isNot(contains('已经做完的事')));
      // 今天到期的单独列一段。
      expect(snap, contains('今天到期且未完成'));
    });

    test('读数据抛异常时不阻断：快照照样返回、不向上抛', () async {
      final ProviderContainer broken = ProviderContainer(
        overrides: [
          taskRepositoryProvider.overrideWithValue(_ThrowingTaskRepository()),
          timetableRepositoryProvider.overrideWithValue(
            FakeTimetableRepository(),
          ),
        ],
      );
      addTearDown(broken.dispose);

      // 快照自己吞掉读失败：不向上抛，且仍返回能取到的部分（日期块）。
      final String snap = await buildAppStateSnapshot(_RefOf(broken));
      expect(snap, contains('日期：'));
      expect(snap, isNot(contains('未完成的日程')));
    });
  });

  group('wire 组装：快照作为 system 注入', () {
    test('appState 为空串 → 不注入额外 system（与改造前一致）', () {
      final List<dynamic> wire = composeWireMessages(
        userText: '我明天有课吗',
        history: const [],
      );
      expect(
        wire.where((dynamic m) => m.role.toString().contains('system')),
        hasLength(1),
      );
    });

    test('appState 非空 → 紧跟在主 system 之后注入，且带防误用说明', () {
      final List<dynamic> wire = composeWireMessages(
        userText: '我今天有什么课',
        history: const [],
        appState: '日期：2026-11-01（周日）\n今天没有课',
      );
      expect(wire.length, 3);
      final String block = (wire[1] as dynamic).text as String;
      expect(block, contains('日期：2026-11-01（周日）'));
      expect(block, contains('不要再调用工具'));
      expect(block, contains('重新查询'));
      // 用户原话最后一条。
      expect((wire.last as dynamic).text, '我今天有什么课');
    });
  });
}

/// 所有读取都抛异常的仓储：验证快照不把异常抛给发送流程。
class _ThrowingTaskRepository extends FakeTaskRepository {
  @override
  Future<List<Task>> getTasks({
    TaskType? type,
    bool? completed,
    DateTime? from,
    DateTime? to,
  }) async => throw StateError('数据库读失败（模拟）');
}
