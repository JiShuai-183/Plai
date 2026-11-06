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
  }) => AiConversationController(
    client: client,
    repository: repository,
    sessionId: 1,
    systemPrompt: '测试',
    tools: [operation ?? tool],
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
