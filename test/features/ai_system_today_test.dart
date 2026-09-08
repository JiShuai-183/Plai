import 'package:flutter_test/flutter_test.dart';

import 'package:plai/data/models/chat_message.dart';
import 'package:plai/features/ai/ai_providers.dart';
import 'package:plai/services/ai/models/ai_message.dart';

/// 隔天继续旧会话时，wire 首条 system 必须带上「当前真实日期」锚点，
/// 覆盖历史里残留的更早日期（避免模型把「今天」当成昨天）。
void main() {
  String two(int n) => n.toString().padLeft(2, '0');

  test('wire 首条 system 含当前真实日期锚点', () {
    final DateTime now = DateTime.now();
    final String today = '${now.year}-${two(now.month)}-${two(now.day)}';

    // 模拟昨天会话：历史 user 提到旧日期、含旧 get_date_info 结果文本。
    final ChatMessage history = ChatMessage(
      id: 1,
      sessionId: 1,
      role: ChatRole.user,
      content: '今天有哪些课？昨天（$today 前一天）问过',
      createdAt: now.subtract(const Duration(days: 1)),
    );

    final List<AiMessage> wire = composeWireMessages(
      userText: '那今天呢',
      history: <ChatMessage>[history],
    );
    expect(wire.first.role, AiRole.system);
    expect(wire.first.text, contains('今天是 $today'));
    expect(wire.first.text, contains('以本条为准'));
  });
}
