import 'package:flutter_test/flutter_test.dart';

import 'package:plai/data/models/chat_message.dart';
import 'package:plai/features/ai/ai_providers.dart';
import 'package:plai/services/ai/models/ai_message.dart';

/// composeWireMessages：历史含工具调用消息时的 wire 组装
/// （回放映射 / 孤儿与不完整防护 / 截断原子性）。
void main() {
  ChatMessage msg(
    ChatRole role,
    String content, {
    List<Map<String, dynamic>>? toolRecords,
  }) =>
      ChatMessage(
        sessionId: 1,
        role: role,
        content: content,
        toolRecords: toolRecords,
      );

  Map<String, dynamic> callsRecord({String id = 'c1', int count = 1}) =>
      <String, dynamic>{
        'type': 'tool_calls',
        'calls': <Map<String, dynamic>>[
          for (int i = 0; i < count; i++)
            <String, dynamic>{
              'id': count == 1 ? id : '${id}_$i',
              'name': 'get_courses',
              'arguments': '{}',
            },
        ],
      };

  Map<String, dynamic> resultRecord({String id = 'c1'}) =>
      <String, dynamic>{
        'type': 'tool_result',
        'tool_call_id': id,
        'name': 'get_courses',
      };

  test('工具轮历史回放：assistant(tool_calls) + tool 结果按原样映射', () {
    final List<ChatMessage> history = <ChatMessage>[
      msg(ChatRole.user, '看课表'),
      msg(ChatRole.assistant, '', toolRecords: <Map<String, dynamic>>[
        callsRecord(),
      ]),
      msg(ChatRole.tool, '[课程列表]', toolRecords: <Map<String, dynamic>>[
        resultRecord(),
      ]),
      msg(ChatRole.assistant, '你有这些课'),
    ];
    final List<AiMessage> wire =
        composeWireMessages(userText: '继续', history: history);

    // system + user + assistant(tc) + tool + assistant + user
    expect(wire.length, 6);
    expect(wire[1].role, AiRole.user);
    expect(wire[1].text, '看课表');
    expect(wire[2].role, AiRole.assistant);
    expect(wire[2].toolCalls?.single.id, 'c1');
    expect(wire[2].text, isNull); // 纯工具轮 content 走 ''
    expect(wire[3].role, AiRole.tool);
    expect(wire[3].toolCallId, 'c1');
    expect(wire[3].text, '[课程列表]');
    expect(wire[4].role, AiRole.assistant);
    expect(wire[4].text, '你有这些课');
    expect(wire.last.role, AiRole.user);
  });

  test('孤儿 tool 消息被丢弃，不产生无归属的 tool wire', () {
    final List<ChatMessage> history = <ChatMessage>[
      msg(ChatRole.user, 'hi'),
      msg(ChatRole.tool, '孤立结果', toolRecords: <Map<String, dynamic>>[
        resultRecord(),
      ]),
      msg(ChatRole.assistant, '回答'),
    ];
    final List<AiMessage> wire =
        composeWireMessages(userText: 'x', history: history);
    expect(wire.any((AiMessage m) => m.role == AiRole.tool), isFalse);
    // system + user + assistant + user
    expect(wire.length, 4);
  });

  test('工具轮缺结果（中途失败/未配齐）降级为纯文本 assistant', () {
    // 场景 A：末尾工具轮只有 1/2 个结果。
    final List<ChatMessage> historyA = <ChatMessage>[
      msg(ChatRole.user, 'hi'),
      msg(ChatRole.assistant, '', toolRecords: <Map<String, dynamic>>[
        callsRecord(count: 2),
      ]),
      msg(ChatRole.tool, '结果1', toolRecords: <Map<String, dynamic>>[
        resultRecord(id: 'c1_0'),
      ]),
    ];
    final List<AiMessage> wireA =
        composeWireMessages(userText: 'x', history: historyA);
    expect(wireA.any((AiMessage m) => m.role == AiRole.tool), isFalse);
    expect(wireA.any((AiMessage m) => m.toolCalls?.isNotEmpty ?? false),
        isFalse);

    // 场景 B：结果没配齐就来了下一条 user（组中途被关闭）。
    final List<ChatMessage> historyB = <ChatMessage>[
      msg(ChatRole.user, 'hi'),
      msg(ChatRole.assistant, '', toolRecords: <Map<String, dynamic>>[
        callsRecord(count: 2),
      ]),
      msg(ChatRole.tool, '结果1', toolRecords: <Map<String, dynamic>>[
        resultRecord(id: 'c1_0'),
      ]),
      msg(ChatRole.user, '算了'),
    ];
    final List<AiMessage> wireB =
        composeWireMessages(userText: 'x', history: historyB);
    expect(wireB.any((AiMessage m) => m.role == AiRole.tool), isFalse);
    expect(wireB.any((AiMessage m) => m.toolCalls?.isNotEmpty ?? false),
        isFalse);
  });

  test('超限截断按整轮丢弃：截断说明与保留范围正确', () {
    // 25 组单条消息（user/assistant 交替）→ 保留最近 20 组，丢弃 5 条。
    final List<ChatMessage> history = <ChatMessage>[
      for (int i = 0; i < 25; i++)
        msg(i.isEven ? ChatRole.user : ChatRole.assistant, 'm$i'),
    ];
    final List<AiMessage> wire =
        composeWireMessages(userText: '新问题', history: history);
    // system + 截断说明 + 20 条 + user
    expect(wire.length, 23);
    expect(wire[1].role, AiRole.system);
    expect(wire[1].text, contains('20'));
    expect(wire[1].text, contains('5'));
    expect(wire[2].text, 'm5'); // 最早的 5 条被丢弃
  });

  test('截断不拆散工具轮：保留区内每条 tool 前面都是带 tool_calls 的 assistant',
      () {
    // 9 个 user 单条组 + 1 个完整工具轮组（2 条）+ 10 个 user 单条组 = 20 组；
    // 再加 2 个 user 组触发截断 → 共 22 组，保留最近 20 组（丢 2 个 user 组），
    // 工具轮组完整保留在保留区内。
    final List<ChatMessage> history = <ChatMessage>[
      for (int i = 0; i < 9; i++) msg(ChatRole.user, 'q$i'),
      msg(ChatRole.assistant, '', toolRecords: <Map<String, dynamic>>[
        callsRecord(id: 'cX'),
      ]),
      msg(ChatRole.tool, '结果X', toolRecords: <Map<String, dynamic>>[
        resultRecord(id: 'cX'),
      ]),
      for (int i = 9; i < 19; i++) msg(ChatRole.user, 'q$i'),
      msg(ChatRole.user, '触发截断1'),
      msg(ChatRole.user, '触发截断2'),
    ];
    final List<AiMessage> wire =
        composeWireMessages(userText: '新问题', history: history);
    // system + 截断说明 + 保留 20 组（丢弃 q0/q1 后：7 user + 工具轮 2 条
    // + 10 user + 2 user = 21 条）+ user
    expect(wire.length, 1 + 1 + 21 + 1);
    for (int i = 0; i < wire.length; i++) {
      if (wire[i].role != AiRole.tool) continue;
      final AiMessage prev = wire[i - 1];
      expect(prev.role, AiRole.assistant);
      expect(prev.toolCalls?.isNotEmpty ?? false, isTrue);
    }
    expect(wire.any((AiMessage m) => m.text == '结果X'), isTrue);
  });
}
