import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/chat_message.dart';
import 'package:plai/data/repositories/chat_repository.dart';
import 'package:plai/features/ai/ai_conversation_controller.dart';
import 'package:plai/services/ai/ai_error.dart';
import 'package:plai/services/ai/llm_client.dart';
import 'package:plai/services/ai/models/ai_message.dart';
import 'package:plai/services/ai/models/ai_tool.dart';

class _Repository implements IChatRepository {
  final messages = <ChatMessage>[];
  @override
  Future<int> appendMessage(ChatMessage message) async {
    messages.add(message);
    return messages.length;
  }

  @override
  Future<int> touchSession(int id) async => 1;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends LlmClient {
  _Client(this.turns) : super(baseUrl: 'https://example.com/v1', model: 'test');
  final List<Object> turns;
  int requests = 0;
  bool closed = false;
  @override
  Future<LlmChatResult> chatStream({
    required List<AiMessage> messages,
    List<Map<String, dynamic>>? tools,
    Object? toolChoice,
    bool jsonMode = false,
    double? temperature,
    Duration? timeout,
    int maxRetries = LlmClient.defaultMaxRetries,
    void Function(LlmDelta)? onDelta,
  }) async {
    final turn = turns[requests++];
    if (turn is AiError) throw turn;
    final result = turn as LlmChatResult;
    // 每个字都单独到达，确保控制器从不把首段当成完整答复。
    for (final rune in (result.content ?? '').runes) {
      onDelta?.call(LlmDelta(contentDelta: String.fromCharCode(rune)));
    }
    return result;
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

AiToolCall _call(String id, String title) => AiToolCall(
  id: id,
  name: 'save_task',
  argumentsJson: jsonEncode({'title': title}),
);
LlmChatResult _writes(List<AiToolCall> calls) => LlmChatResult(
  content: '我将提交修改',
  toolCalls: calls,
  finishReason: 'tool_calls',
);

void main() {
  late _Repository repository;
  late List<String> executed;
  late int confirmations;
  late AiConversationTool tool;
  setUp(() {
    repository = _Repository();
    executed = [];
    confirmations = 0;
    tool = AiConversationTool(
      name: 'save_task',
      label: '日程',
      schema: {},
      validate: (args) =>
          (args['title'] as String? ?? '').isEmpty ? '缺少标题' : null,
      intentKey: (args) => jsonEncode(args),
      describe: (args) async => '新建任务「${args['title']}」',
      execute: (args) async {
        executed.add(args['title'] as String);
        return '{"status":"created"}';
      },
    );
  });

  AiConversationController controller(
    _Client client, {
    AiConfirmWrites? confirm,
    AiConversationTool? operation,
    Map<String, dynamic> checkpoint = const {},
    Future<void> Function(Map<String, dynamic>)? onCheckpoint,
    Future<List<AiWriteProposal>> Function(List<AiWriteProposal>)?
    prepareWrites,
  }) => AiConversationController(
    client: client,
    repository: repository,
    sessionId: 1,
    systemPrompt: '测试',
    tools: [operation ?? tool],
    checkpoint: checkpoint,
    onCheckpoint: onCheckpoint,
    prepareWrites: prepareWrites,
    confirmWrites:
        confirm ??
        (proposals) async {
          confirmations++;
          return [for (final proposal in proposals) Map.of(proposal.args)];
        },
    onState: (_) {},
    onMessagesChanged: () {},
  );

  Future<void> run(AiConversationController value) => value.run(
    messages: [AiMessage.user('执行我的安排')],
    userText: '执行我的安排',
    writeEnabled: true,
  );
  String text() => repository.messages
      .where((m) => m.role == ChatRole.assistant)
      .map((m) => m.content)
      .join('\n');

  test(
    'prepared arguments and edited drafts survive restart with one intent',
    () async {
      Map<String, dynamic> saved = {};
      late List<AiWriteProposal> pending;
      final waiting = Completer<List<Map<String, dynamic>?>>();
      final first = controller(
        _Client([
          _writes([_call('1', '数学'), _call('2', '英语')]),
        ]),
        onCheckpoint: (value) async => saved = jsonDecode(jsonEncode(value)),
        prepareWrites: (proposals) async => [
          for (final proposal in proposals)
            AiWriteProposal(
              tool: proposal.tool,
              args: {
                ...proposal.args,
                'photos': [1],
              },
              description: proposal.description,
            ),
        ],
        confirm: (proposals) {
          pending = proposals;
          return waiting.future;
        },
      );
      final running = run(first);
      while (saved.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(Duration.zero);
      await pending.first.updateDraft({
        'title': '新数学',
        'photos': [2],
      });
      expect(pending.first.args['title'], '新数学');
      expect((saved['operations'] as List), hasLength(2));
      expect((saved['operations'] as List).first['args']['photos'], [2]);
      expect((saved['operations'] as List).last['args']['title'], '英语');
      // Mutable nested values returned to a caller cannot mutate the proposal.
      (pending.first.args['photos'] as List).add(4);
      expect(pending.first.args['photos'], [2]);
      first.cancel();
      waiting.complete([null, null]);
      await running;
      var prepares = 0;
      await run(
        controller(
          _Client([]),
          checkpoint: saved,
          prepareWrites: (_) async {
            prepares++;
            throw StateError('must not reprepare');
          },
          confirm: (proposals) async {
            expect(proposals.first.args['title'], '新数学');
            expect(proposals.first.args['photos'], [2]);
            return [for (final proposal in proposals) Map.of(proposal.args)];
          },
        ),
      );
      expect(prepares, 0);
      expect(executed, ['新数学', '英语']);
    },
  );

  test(
    'failed draft persistence retains original proposal and checkpoint',
    () async {
      var reject = false;
      late AiConversationController value;
      value = controller(
        _Client([
          _writes([_call('1', '数学')]),
        ]),
        onCheckpoint: (_) async {
          if (reject) throw StateError('disk failure');
        },
        confirm: (proposals) async {
          final before = jsonEncode(value.checkpoint);
          reject = true;
          await expectLater(
            proposals.single.updateDraft({'title': '物理'}),
            throwsStateError,
          );
          expect(proposals.single.args['title'], '数学');
          expect(jsonEncode(value.checkpoint), before);
          reject = false;
          await proposals.single.updateDraft({'title': '英语'});
          return [Map.of(proposals.single.args)];
        },
      );
      await run(value);
      expect(executed, ['英语']);
      expect(value.checkpoint['operations'], hasLength(1));
    },
  );

  test(
    'different proposals serialize draft checkpoints without dropping either',
    () async {
      await run(
        controller(
          _Client([
            _writes([_call('1', '数学'), _call('2', '英语')]),
          ]),
          confirm: (proposals) async {
            await Future.wait([
              proposals[0].updateDraft({'title': '新数学'}),
              proposals[1].updateDraft({'title': '新英语'}),
            ]);
            return [for (final proposal in proposals) Map.of(proposal.args)];
          },
        ),
      );
      expect(executed, ['新数学', '新英语']);
    },
  );

  test(
    'draft edits cannot collide with a succeeded or another pending intent',
    () async {
      await run(
        controller(
          _Client([]),
          checkpoint: {
            'operations': [
              {
                'key': 'save_task:${jsonEncode({'title': '已完成'})}',
                'tool': 'save_task',
                'args': {'title': '已完成'},
                'description': '已完成',
                'status': 'succeeded',
                'output': '{"status":"created"}',
              },
              {
                'key': 'save_task:${jsonEncode({'title': '待确认'})}',
                'tool': 'save_task',
                'args': {'title': '待确认'},
                'description': '待确认',
                'status': 'unconfirmed',
              },
            ],
          },
          confirm: (proposals) async {
            expect(proposals, hasLength(1));
            await expectLater(
              proposals.single.updateDraft({'title': '已完成'}),
              throwsStateError,
            );
            expect(proposals.single.args['title'], '待确认');
            return [Map.of(proposals.single.args)];
          },
        ),
      );
      expect(executed, ['待确认']);
    },
  );

  test('preparation cannot reorder tools or change batch length', () async {
    final value = controller(
      _Client([
        _writes([_call('1', '数学')]),
      ]),
      prepareWrites: (_) async => [],
      confirm: (_) async {
        fail('must not confirm malformed preparation');
      },
    );
    await expectLater(run(value), throwsA(isA<AiError>()));
    expect(executed, isEmpty);
    expect(value.checkpoint, isEmpty);
  });

  test(
    'prepared bindings do not allow the original model intent to replay',
    () async {
      var preparations = 0;
      await run(
        controller(
          _Client([
            _writes([
              _call('1', '数学'),
              const AiToolCall(
                id: 'bad',
                name: 'save_task',
                argumentsJson: '{}',
              ),
            ]),
            _writes([_call('2', '数学')]),
          ]),
          prepareWrites: (proposals) async {
            preparations++;
            return [
              for (final proposal in proposals)
                AiWriteProposal(
                  tool: proposal.tool,
                  args: {...proposal.args, 'binding': preparations},
                  description: proposal.description,
                ),
            ];
          },
        ),
      );
      expect(executed, ['数学']);
      expect(preparations, 1);
    },
  );

  test(
    'rejected prepared intent is not proposed again under its canonical key',
    () async {
      var prompts = 0;
      await run(
        controller(
          _Client([
            _writes([
              _call('1', '数学'),
              const AiToolCall(
                id: 'bad',
                name: 'save_task',
                argumentsJson: '{}',
              ),
            ]),
            _writes([
              AiToolCall(
                id: '2',
                name: 'save_task',
                argumentsJson: jsonEncode({'title': '数学', 'binding': 1}),
              ),
            ]),
          ]),
          prepareWrites: (proposals) async => [
            for (final p in proposals)
              AiWriteProposal(
                tool: p.tool,
                args: {...p.args, 'binding': 1},
                description: p.description,
              ),
          ],
          confirm: (proposals) async {
            prompts++;
            return [for (final _ in proposals) null];
          },
        ),
      );
      expect(prompts, 1);
      expect(executed, isEmpty);
    },
  );

  test(
    'merged model intents remain handled when preparation later changes',
    () async {
      var preparations = 0;
      await run(
        controller(
          _Client([
            _writes([
              _call('1', '数学'),
              _call('2', '英语'),
              const AiToolCall(
                id: 'bad',
                name: 'save_task',
                argumentsJson: '{}',
              ),
            ]),
            _writes([_call('3', '英语')]),
          ]),
          prepareWrites: (proposals) async {
            preparations++;
            return [
              for (final p in proposals)
                AiWriteProposal(
                  tool: p.tool,
                  args: {'title': '英语', 'binding': preparations},
                  description: p.description,
                ),
            ];
          },
        ),
      );
      expect(preparations, 1);
      expect(executed, ['英语']);
    },
  );

  test(
    'preparation that matches a handled intent never opens empty confirmation',
    () async {
      var prompts = 0;
      await run(
        controller(
          _Client([
            _writes([
              _call('1', '数学'),
              const AiToolCall(
                id: 'bad',
                name: 'save_task',
                argumentsJson: '{}',
              ),
            ]),
            _writes([_call('2', '英语')]),
          ]),
          prepareWrites: (proposals) async => [
            for (final p in proposals)
              AiWriteProposal(
                tool: p.tool,
                args: {'title': '统一任务'},
                description: p.description,
              ),
          ],
          confirm: (proposals) async {
            prompts++;
            expect(proposals, isNotEmpty);
            return [for (final p in proposals) p.args];
          },
        ),
      );
      expect(prompts, 1);
      expect(executed, ['统一任务']);
    },
  );

  test(
    'concurrent edits publish arguments and descriptions in durable order',
    () async {
      final gate = Completer<void>();
      final described = Completer<void>();
      final writes = <String>[];
      final proposal = AiWriteProposal(
        tool: AiConversationTool(
          name: 'save_task',
          label: '日程',
          schema: {},
          execute: (_) async => '',
          describe: (args) async {
            if (args['title'] == '数学') {
              described.complete();
              await gate.future;
            }
            return args['title'] as String;
          },
        ),
        args: {'title': '原标题'},
        description: '原标题',
        onDraftChanged: (args) async => writes.add(args['title'] as String),
      );
      final first = proposal.updateDraft({'title': '数学'});
      await described.future;
      final second = proposal.updateDraft({'title': '英语'});
      await Future<void>.delayed(Duration.zero);
      expect(writes, ['数学']);
      expect(proposal.args['title'], '原标题');
      gate.complete();
      await Future.wait([first, second]);
      expect(writes, ['数学', '英语']);
      expect(proposal.args['title'], '英语');
      expect(proposal.description, '英语');
    },
  );

  test('持久检查点恢复只确认和重试失败项，已成功项不重放', () async {
    var failPhysics = true;
    final op = AiConversationTool(
      name: tool.name,
      label: tool.label,
      schema: tool.schema,
      validate: tool.validate,
      intentKey: tool.intentKey,
      describe: tool.describe,
      execute: (args) async {
        executed.add(args['title'] as String);
        return args['title'] == '物理' && failPhysics
            ? '{"status":"error","error":"保存失败"}'
            : '{"status":"created"}';
      },
    );
    var saved = <String, dynamic>{};
    final first = controller(
      _Client([
        _writes([_call('a', '高数'), _call('b', '物理')]),
      ]),
      operation: op,
      onCheckpoint: (value) async {
        saved = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
      },
    );
    await run(first);
    expect(first.hadFailures, isTrue);
    failPhysics = false;
    final client = _Client([]);
    final retry = controller(
      client,
      operation: op,
      checkpoint: saved,
      confirm: (proposals) async {
        expect(proposals.map((p) => p.args['title']), ['物理']);
        return [proposals.single.args];
      },
    );
    await run(retry);
    expect(executed, ['高数', '物理', '物理']);
    expect(client.requests, 0);
    expect(retry.hadFailures, isFalse);
  });

  test('写后检查点保存中断，保留未知项及未开始项供人工核对选择', () async {
    var durable = <String, dynamic>{};
    final first = controller(
      _Client([
        _writes([_call('a', '高数'), _call('b', '物理')]),
      ]),
      onCheckpoint: (value) async {
        final ops = value['operations'] as List;
        if (ops.any((e) => e['status'] == 'succeeded')) {
          throw StateError('落库失败');
        }
        durable = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
      },
    );
    await expectLater(run(first), throwsStateError);
    expect(executed, ['高数']);
    expect((durable['operations'] as List).map((e) => e['status']), [
      'running',
      'pending',
    ]);
    final retry = controller(
      _Client([]),
      checkpoint: durable,
      confirm: (proposals) async {
        expect(proposals.map((p) => p.args['title']), ['高数', '物理']);
        return [null, proposals.last.args];
      },
    );
    await run(retry);
    expect(executed, ['高数', '物理']);
  });

  test('保存执行前日志失败不进入业务写入', () async {
    final value = controller(
      _Client([
        _writes([_call('a', '高数')]),
      ]),
      onCheckpoint: (value) async {
        throw StateError('存储失败');
      },
    );
    await expectLater(run(value), throwsStateError);
    expect(executed, isEmpty);
  });

  test('恢复时将失败草稿编辑为已成功意图，不覆盖成功日志或重复执行', () async {
    final done = {'title': '高数'};
    final failed = {'title': '物理'};
    final value = controller(
      _Client([]),
      checkpoint: {
        'operations': [
          {
            'key': 'save_task:${jsonEncode(done)}',
            'tool': 'save_task',
            'args': done,
            'description': '高数',
            'status': 'succeeded',
            'output': '{"status":"created"}',
          },
          {
            'key': 'save_task:${jsonEncode(failed)}',
            'tool': 'save_task',
            'args': failed,
            'description': '物理',
            'status': 'failed',
          },
        ],
      },
      confirm: (proposals) async => [done],
    );
    await run(value);
    expect(executed, isEmpty);
    expect(
      (value.checkpoint['operations'] as List).first['status'],
      'succeeded',
    );
  });

  test('批量提案一次确认，同批重复项不执行；纯写只请求一轮', () async {
    final client = _Client([
      _writes([_call('a', '高数'), _call('b', '高数'), _call('c', '物理')]),
    ]);
    final value = controller(client);
    await run(value);
    expect(executed, ['高数', '物理']);
    expect(confirmations, 1);
    expect(client.requests, 1);
    expect(client.closed, isTrue);
    expect(value.state.running, isFalse);
    expect(text(), contains('已完成：新建任务「物理」'));
    expect(text(), isNot(contains('我将提交修改')));
    expect(
      repository.messages.where((m) => m.role == ChatRole.tool),
      hasLength(3),
    );
  });

  test('确认时编辑草稿，执行和结果文案都使用修改后的值', () async {
    final value = controller(
      _Client([
        _writes([_call('a', '原名')]),
      ]),
      confirm: (_) async => [
        {'title': '编辑后的名称'},
      ],
    );
    await run(value);
    expect(executed, ['编辑后的名称']);
    expect(text(), contains('已完成：新建任务「编辑后的名称」'));
    expect(text(), isNot(contains('已完成：新建任务「原名」')));
  });

  test('全部取消直接由 App 收尾，不执行、不向模型再请求汇报', () async {
    final client = _Client([
      _writes([_call('a', '高数'), _call('b', '物理')]),
    ]);
    await run(controller(client, confirm: (_) async => [null, null]));
    expect(executed, isEmpty);
    expect(client.requests, 1);
    expect(text(), contains('已跳过：'));
    expect(text(), isNot(contains('已完成：')));
  });

  test('无效模型参数交回修正，只有有效提案才能弹一次确认', () async {
    final client = _Client([
      _writes([_call('a', '')]),
      _writes([_call('b', '高数')]),
    ]);
    await run(controller(client));
    expect(client.requests, 2);
    expect(confirmations, 1);
    expect(executed, ['高数']);
    expect(
      repository.messages.firstWhere((m) => m.role == ChatRole.tool).content,
      contains('缺少标题'),
    );
  });

  test('用户编辑后无效的草稿会重新校验，不进入执行', () async {
    await run(
      controller(
        _Client([
          _writes([_call('a', '高数')]),
        ]),
        confirm: (_) async => [
          {'title': ''},
        ],
      ),
    );
    expect(executed, isEmpty);
    expect(text(), contains('未完成：'));
    expect(text(), contains('缺少标题'));
  });

  test('部分失败如实显示，不重放成功项；用户重新发起后再次确认才执行', () async {
    int failures = 1;
    final failing = AiConversationTool(
      name: tool.name,
      label: tool.label,
      schema: tool.schema,
      validate: tool.validate,
      intentKey: tool.intentKey,
      describe: tool.describe,
      execute: (args) async {
        if (args['title'] == '物理' && failures-- > 0) {
          return '{"status":"error","error":"保存失败"}';
        }
        return tool.execute(args);
      },
    );
    final first = _Client([
      _writes([_call('a', '高数'), _call('b', '物理')]),
    ]);
    await run(controller(first, operation: failing));
    expect(executed, ['高数']);
    expect(first.requests, 1);
    expect(text(), contains('未完成：新建任务「物理」'));
    expect(text(), isNot(contains('已完成：新建任务「物理」')));
    await run(
      controller(
        _Client([
          _writes([_call('c', '物理')]),
        ]),
        operation: failing,
      ),
    );
    expect(confirmations, 2);
    expect(executed, ['高数', '物理']);
  });

  test('页面销毁时取消，晚到的确认不得执行', () async {
    final shown = Completer<void>();
    final decision = Completer<List<Map<String, dynamic>?>>();
    final client = _Client([
      _writes([_call('a', '高数')]),
    ]);
    final value = controller(
      client,
      confirm: (_) {
        shown.complete();
        return decision.future;
      },
    );
    final pending = run(value);
    await shown.future;
    value.cancel();
    decision.complete([
      {'title': '高数'},
    ]);
    await pending;
    expect(executed, isEmpty);
    expect(client.closed, isTrue);
  });

  test('网络失败释放忙状态，不写数据；下一次发送可正常重试', () async {
    final client = _Client([const AiError(AiErrorKind.network, '断开连接')]);
    final value = controller(client);
    await expectLater(run(value), throwsA(isA<AiError>()));
    expect(value.state.running, isFalse);
    expect(client.closed, isTrue);
    expect(executed, isEmpty);
    await run(
      controller(
        _Client([
          _writes([_call('a', '高数')]),
        ]),
      ),
    );
    expect(executed, ['高数']);
  });

  test('正常文本逐字到达仍完整落库', () async {
    final value = controller(
      _Client([const LlmChatResult(content: '这是完整的流式回复。')]),
    );
    await run(value);
    expect(text(), '这是完整的流式回复。');
    expect(confirmations, 0);
  });
}
