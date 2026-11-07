import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/chat_message.dart';
import 'package:plai/data/models/chat_queue_entry.dart';
import 'package:plai/features/ai/ai_queue_attachments.dart';
import 'package:plai/features/ai/ai_queue_controller.dart';

import 'ai_page_test.dart' show FakeChatRepository, FakeChatQueueRepository;

class _FaultyQueueRepository extends FakeChatQueueRepository {
  _FaultyQueueRepository(super.chat);
  bool failAfterClaim = false;
  bool failAfterEnqueue = false;
  bool failNextList = false;
  int recoverCalls = 0;
  @override
  Future<int> recoverInterrupted() {
    recoverCalls++;
    return super.recoverInterrupted();
  }

  @override
  Future<List<ChatQueueEntry>> list({int? sessionId}) async {
    if (failNextList) {
      failNextList = false;
      throw StateError('读取失败');
    }
    return super.list(sessionId: sessionId);
  }

  @override
  Future<ChatQueueEntry> enqueue({
    required int sessionId,
    required String text,
    List<String> imagePaths = const [],
    bool includeAppState = false,
  }) async {
    final result = await super.enqueue(
      sessionId: sessionId,
      text: text,
      imagePaths: imagePaths,
      includeAppState: includeAppState,
    );
    if (failAfterEnqueue) {
      failAfterEnqueue = false;
      failNextList = true;
    }
    return result;
  }

  @override
  Future<int> update(
    int id, {
    ChatQueueStatus? status,
    String? error,
    Map<String, dynamic>? checkpoint,
    bool clearError = false,
  }) async {
    final result = await super.update(
      id,
      status: status,
      error: error,
      checkpoint: checkpoint,
      clearError: clearError,
    );
    if (failAfterClaim && status == ChatQueueStatus.running) {
      failAfterClaim = false;
      failNextList = true;
    }
    return result;
  }
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 500; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('队列未到达预期状态');
}

void main() {
  late FakeChatRepository chat;
  late FakeChatQueueRepository repo;
  late int a;
  late int b;
  AiQueueController make(AiQueuedRunner runner) => AiQueueController(
    repository: repo,
    run: runner,
    attachments: AiQueueAttachments(),
    onMessagesChanged: (_) {},
    errorMessage: (_) => '失败',
  );
  setUp(() {
    chat = FakeChatRepository();
    repo = FakeChatQueueRepository(chat);
    a = chat.seedSession(title: 'A').id!;
    b = chat.seedSession(title: 'B').id!;
  });

  test('跨会话FIFO串行；处理中仍可继续入队', () async {
    final gate = Completer<void>();
    final order = <String>[];
    final q = make((e, state, confirm, checkpoint) async {
      order.add(e.text);
      if (order.length == 1) await gate.future;
      return true;
    });
    addTearDown(q.dispose);
    await q.initialize();
    await q.enqueue(sessionId: a, text: 'A1');
    await until(() => q.active != null);
    await q.enqueue(sessionId: b, text: 'B1');
    await q.enqueue(sessionId: a, text: 'A2');
    expect(order, ['A1']);
    expect(q.queuedCount, 2);
    gate.complete();
    await until(() => q.entries.every(AiQueueController.isTerminal));
    expect(order, ['A1', 'B1', 'A2']);
  });

  test('排队撤回和取消原子移除未发送历史，不影响当前执行', () async {
    final gate = Completer<void>();
    final q = make((e, state, confirm, checkpoint) async {
      await gate.future;
      return true;
    });
    addTearDown(q.dispose);
    await q.initialize();
    final running = await q.enqueue(sessionId: a, text: '运行');
    await until(() => q.active != null);
    final queued = await q.enqueue(sessionId: b, text: '撤回内容');
    expect(await q.withdraw(running.id), isNull);
    final removed = await q.withdraw(queued.id);
    expect(removed!.text, '撤回内容');
    expect(chat.messagesOf(b), isEmpty);
    final cancelled = await q.enqueue(sessionId: b, text: '取消内容');
    await q.cancelQueued(cancelled.id);
    expect(chat.messagesOf(b), isEmpty);
    gate.complete();
    await until(() => q.activeId == null);
  });

  test('失败暂停；重试原项成功后继续，不越过失败消息', () async {
    var calls = 0;
    final order = <String>[];
    final gate = Completer<void>();
    final q = make((e, state, confirm, checkpoint) async {
      order.add(e.text);
      calls++;
      if (calls == 1) {
        await gate.future;
        return false;
      }
      return true;
    });
    addTearDown(q.dispose);
    await q.initialize();
    final first = await q.enqueue(sessionId: a, text: '失败项');
    await q.enqueue(sessionId: b, text: '后续项');
    gate.complete();
    await until(() => q.blocked != null);
    expect(q.paused, isTrue);
    expect(order, ['失败项']);
    await q.retry(first.id);
    await until(() => q.entries.every(AiQueueController.isTerminal));
    expect(order, ['失败项', '失败项', '后续项']);
  });

  test('待确认阻塞队列，来源会话禁止删除；确认跳过后继续', () async {
    final seen = <int>[];
    final q = make((e, state, confirm, checkpoint) async {
      seen.add(e.sessionId);
      if (e.sessionId == a) {
        final result = await confirm(const []);
        expect(result, isEmpty);
      }
      return true;
    });
    addTearDown(q.dispose);
    await q.initialize();
    await q.enqueue(sessionId: a, text: '待确认');
    await until(() => q.confirmation != null);
    await q.enqueue(sessionId: b, text: '后续');
    expect(seen, [a]);
    expect(q.sessionLocked(a), isTrue);
    await expectLater(q.deleteSessions([a]), throwsStateError);
    q.confirm([]);
    await until(() => q.entries.every(AiQueueController.isTerminal));
    expect(seen, [a, b]);
  });

  test('重启标记运行项中断，排队项必须手动恢复', () async {
    final first = await repo.enqueue(sessionId: a, text: '中断');
    await repo.update(first.id, status: ChatQueueStatus.running);
    await repo.enqueue(sessionId: b, text: '待恢复');
    final seen = <String>[];
    final q = make((e, state, confirm, checkpoint) async {
      seen.add(e.text);
      return true;
    });
    addTearDown(q.dispose);
    await q.initialize();
    expect(q.restored, isTrue);
    expect(q.paused, isTrue);
    expect(q.blocked!.status, ChatQueueStatus.interrupted);
    expect(seen, isEmpty);
    await q.resume();
    expect(seen, isEmpty);
    await q.skip(first.id);
    await until(() => q.entries.every(AiQueueController.isTerminal));
    expect(seen, ['待恢复']);
  });

  test('只有未开始消息时，重启也不会自动发出', () async {
    await repo.enqueue(sessionId: a, text: '等待手动');
    var calls = 0;
    final q = make((e, state, confirm, checkpoint) async {
      calls++;
      return true;
    });
    addTearDown(q.dispose);
    await q.initialize();
    expect(calls, 0);
    await q.resume();
    await until(() => q.entries.every(AiQueueController.isTerminal));
    expect(calls, 1);
  });

  test('异常保存检查点，失败不会丢失已成功操作记录', () async {
    final q = make((e, state, confirm, checkpoint) async {
      await checkpoint({
        'operations': [
          {'status': 'succeeded', 'key': 'done'},
          {'status': 'running', 'key': 'unknown'},
        ],
      });
      throw StateError('结果尚未落库');
    });
    addTearDown(q.dispose);
    await q.initialize();
    await q.enqueue(sessionId: a, text: '请求');
    await until(() => q.blocked != null);
    expect(q.blocked!.status, ChatQueueStatus.interrupted);
    expect((q.blocked!.checkpoint['operations'] as List).first['key'], 'done');
  });

  test('对话排序将回答放回来源消息后，排队消息不会挤在中间', () async {
    final first = await repo.enqueue(sessionId: a, text: '第一句');
    await repo.enqueue(sessionId: a, text: '第二句');
    await chat.appendMessage(
      ChatMessage(
        sessionId: a,
        role: ChatRole.assistant,
        content: '第一句回复',
        toolRecords: [
          {'type': 'queue', 'id': first.id},
        ],
      ),
    );
    final sorted = orderAiMessages(chat.messagesOf(a), repo.entries);
    expect(sorted.map((m) => m.content), ['第一句', '第一句回复', '第二句']);
  });

  test('认领后读取异常释放活动锁，重新加载后可核对重试', () async {
    final faulty = _FaultyQueueRepository(chat)..failAfterClaim = true;
    repo = faulty;
    var calls = 0;
    final q = make((e, state, confirm, checkpoint) async {
      calls++;
      return true;
    });
    addTearDown(q.dispose);
    await q.initialize();
    final entry = await q.enqueue(sessionId: a, text: '恢复消息');
    await until(() => q.storageError != null);
    expect(q.activeId, isNull);
    expect(calls, 0);
    await q.reloadStorage();
    expect(q.blocked!.status, ChatQueueStatus.interrupted);
    await q.retry(entry.id);
    await until(() => q.entries.every(AiQueueController.isTerminal));
    expect(calls, 1);
  });

  test('入队成功但刷新失败仍返回已保存项，恢复后只执行一次', () async {
    final faulty = _FaultyQueueRepository(chat)..failAfterEnqueue = true;
    repo = faulty;
    var calls = 0;
    final q = make((e, state, confirm, checkpoint) async {
      calls++;
      return true;
    });
    addTearDown(q.dispose);
    await q.initialize();
    final entry = await q.enqueue(sessionId: a, text: '已保存');
    expect(q.entries.single.id, entry.id);
    expect(q.storageError, isNotNull);
    expect(chat.messagesOf(a), hasLength(1));
    expect(calls, 0);
    await q.reloadStorage();
    await q.resume();
    await until(() => q.entries.every(AiQueueController.isTerminal));
    expect(calls, 1);
  });

  for (final waiting in [false, true]) {
    test('活跃${waiting ? '确认' : '执行'}期间入队刷新失败，重新加载保留执行权且不并发', () async {
      final faulty = _FaultyQueueRepository(chat);
      repo = faulty;
      final gate = Completer<void>();
      final order = <String>[];
      var concurrent = 0;
      var maximumConcurrent = 0;
      final q = make((e, state, confirm, checkpoint) async {
        concurrent++;
        if (concurrent > maximumConcurrent) maximumConcurrent = concurrent;
        order.add(e.text);
        try {
          if (e.text == 'A') {
            if (waiting) {
              await confirm(const []);
            } else {
              await gate.future;
            }
          }
          return true;
        } finally {
          concurrent--;
        }
      });
      addTearDown(q.dispose);
      await q.initialize();
      final first = await q.enqueue(sessionId: a, text: 'A');
      await until(() => waiting ? q.confirmation != null : order.isNotEmpty);
      final confirmation = q.confirmation;
      faulty.failAfterEnqueue = true;
      await q.enqueue(sessionId: b, text: 'B');
      expect(q.storageError, isNotNull);
      await q.reloadStorage();
      expect(faulty.recoverCalls, 1);
      expect(q.storageError, isNull);
      expect(q.paused, isTrue);
      expect(q.blocked, isNull);
      expect(q.activeId, first.id);
      expect(
        q.active!.status,
        waiting ? ChatQueueStatus.waitingConfirmation : ChatQueueStatus.running,
      );
      expect(q.confirmation, same(confirmation));
      await q.skip(first.id);
      await q.resume();
      expect(order, ['A']);
      if (waiting) {
        q.confirm([]);
      } else {
        gate.complete();
      }
      await until(() => q.entries.every(AiQueueController.isTerminal));
      expect(order, ['A', 'B']);
      expect(maximumConcurrent, 1);
    });
  }

  test('即使存储中的活跃项已被标记中断，也拒绝跳过仍运行的消息', () async {
    final gate = Completer<void>();
    final q = make((e, state, confirm, checkpoint) async {
      await gate.future;
      return true;
    });
    addTearDown(q.dispose);
    await q.initialize();
    final first = await q.enqueue(sessionId: a, text: 'A');
    await until(() => q.active?.status == ChatQueueStatus.running);
    await repo.update(first.id, status: ChatQueueStatus.interrupted);
    await q.reloadStorage();
    expect(q.blocked!.id, first.id);
    await q.skip(first.id);
    expect(q.blocked!.status, ChatQueueStatus.interrupted);
    gate.complete();
    await until(() => q.activeId == null);
    expect(q.entries.single.status, ChatQueueStatus.completed);
  });
}
