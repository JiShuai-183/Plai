import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/chat_message.dart';
import 'package:plai/data/repositories/chat_repository.dart';
import 'package:plai/features/ai/ai_settings_keys.dart';

import 'test_helpers.dart';

Future<void> _sleep([int ms = 5]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late TestData data;
  late ChatRepository chat;

  setUp(() async {
    data = await TestData.create();
    chat = ChatRepository(data.db);
  });

  tearDown(() async {
    await data.db.close();
  });

  test('createSession → list/get 往返，title 空串、默认不置顶', () async {
    final id = await chat.createSession();
    expect(id, isPositive);

    final sessions = await chat.listSessions();
    expect(sessions, hasLength(1));
    final s = sessions.first;
    expect(s.id, id);
    expect(s.title, '');
    expect(s.pinned, isFalse);

    expect(await chat.getSessionById(id), s);
    expect(await chat.getSessionById(id + 999), isNull);
  });

  test('renameSession 改标题', () async {
    final id = await chat.createSession(title: '草稿');
    expect(await chat.renameSession(id, '课程表问题'), 1);
    final s = await chat.getSessionById(id);
    expect(s!.title, '课程表问题');
  });

  test('appendMessage / messagesFor 往返：role、附件、工具记录类型化访问', () async {
    final sid = await chat.createSession(title: '会话');
    final id1 = await chat.appendMessage(ChatMessage(
      sessionId: sid,
      role: ChatRole.user,
      content: '帮我看看这周课',
      hasContext: true,
      attachments: ['/tmp/shot1.png', '/tmp/shot2.png'],
    ));
    final id2 = await chat.appendMessage(ChatMessage(
      sessionId: sid,
      role: ChatRole.tool,
      content: '{"ok":true}',
      toolRecords: [
        {'toolCallId': 'call_1', 'name': 'query_timetable'},
      ],
    ));
    final id3 = await chat.appendMessage(ChatMessage(
      sessionId: sid,
      role: ChatRole.assistant,
      content: '本周共 8 门课',
    ));
    expect(id2, greaterThan(id1));
    expect(id3, greaterThan(id2));

    final messages = await chat.messagesFor(sid);
    expect(messages, hasLength(3));
    expect(messages.map((m) => m.id), [id1, id2, id3]);

    final m0 = messages[0];
    expect(m0.role, ChatRole.user);
    expect(m0.content, '帮我看看这周课');
    expect(m0.hasContext, isTrue);
    expect(m0.attachments, ['/tmp/shot1.png', '/tmp/shot2.png']);

    final m1 = messages[1];
    expect(m1.role, ChatRole.tool);
    expect(m1.toolRecords.single['toolCallId'], 'call_1');
    expect(m1.toolRecords.single['name'], 'query_timetable');

    // 默认值：无附件 / 无工具记录的消息字段为空。
    expect(messages[2].attachments, isEmpty);
    expect(messages[2].toolRecords, isEmpty);

    // 其他会话读不到本会话消息。
    final sid2 = await chat.createSession();
    expect(await chat.messagesFor(sid2), isEmpty);
  });

  test('updateMessageContent 流式增量落库', () async {
    final sid = await chat.createSession();
    final id = await chat.appendMessage(
      ChatMessage(sessionId: sid, role: ChatRole.assistant, content: ''),
    );
    expect(await chat.updateMessageContent(id, '你'), 1);
    expect(await chat.updateMessageContent(id, '你好'), 1);
    final messages = await chat.messagesFor(sid);
    expect(messages, hasLength(1));
    expect(messages.single.content, '你好');
  });

  test('listSessions 排序：置顶优先 → 其余按 last_active_at 倒序', () async {
    final s1 = await chat.createSession(title: '会话一');
    await _sleep();
    final s2 = await chat.createSession(title: '会话二');

    // 无置顶：最近活跃的 s2 排最前。
    expect((await chat.listSessions()).map((s) => s.id), [s2, s1]);

    // 置顶优先：s1 置顶后压过更活跃的 s2。
    await chat.setPinned(s1, true);
    expect((await chat.listSessions()).map((s) => s.id), [s1, s2]);

    // 取消置顶并让 s1 更活跃 → 按 last_active_at 倒序。
    await chat.setPinned(s1, false);
    await _sleep();
    await chat.touchSession(s1);
    expect((await chat.listSessions()).map((s) => s.id), [s1, s2]);

    // s1 再活跃，但 s2 置顶 → 置顶仍优先。
    await _sleep();
    await chat.touchSession(s1);
    await chat.setPinned(s2, true);
    expect((await chat.listSessions()).map((s) => s.id), [s2, s1]);

    // pinned 标记落库读回。
    expect((await chat.getSessionById(s2))!.pinned, isTrue);
    expect((await chat.getSessionById(s1))!.pinned, isFalse);
  });

  test('deleteSession 级联删除全部消息', () async {
    final sid = await chat.createSession(title: '待删');
    for (var i = 0; i < 3; i++) {
      await chat.appendMessage(
        ChatMessage(sessionId: sid, role: ChatRole.user, content: 'm$i'),
      );
    }
    expect(await chat.messagesFor(sid), hasLength(3));
    expect(await chat.deleteSession(sid), 1);
    expect(await chat.getSessionById(sid), isNull);
    expect(await chat.messagesFor(sid), isEmpty);
  });

  test('AI 设置键走现有 setting 表读写', () async {
    final repo = data.settings;

    // 缺省值契约。
    expect(AiSettingsKeys.defaultLlmEnabled, 'false');
    expect(AiSettingsKeys.defaultLlmBaseUrl, '');
    expect(AiSettingsKeys.defaultLlmModel, '');
    expect(AiSettingsKeys.defaultWriteEnabled, 'false');
    expect(AiSettingsKeys.defaultOcrMode, 'llm');
    expect(AiSettingsKeys.defaultOcrAppKey, '');

    await repo.setValue(AiSettingsKeys.llmBaseUrl, 'https://api.example.com/v1');
    await repo.setValue(AiSettingsKeys.llmApiKey, 'sk-test');
    await repo.setValue(AiSettingsKeys.llmModel, 'gpt-4o');
    await repo.setValue(AiSettingsKeys.writeEnabled, 'true');
    await repo.setValue(AiSettingsKeys.ocrMode, 'provider');
    await repo.setValue(AiSettingsKeys.ocrAppKey, 'app-key-1');

    expect(await repo.getValue(AiSettingsKeys.llmBaseUrl), 'https://api.example.com/v1');
    expect(await repo.getValue(AiSettingsKeys.llmApiKey), 'sk-test');
    expect(await repo.getValue(AiSettingsKeys.llmModel), 'gpt-4o');
    expect(await repo.getValue(AiSettingsKeys.writeEnabled), 'true');
    expect(await repo.getValue(AiSettingsKeys.ocrMode), 'provider');
    expect(await repo.getValue(AiSettingsKeys.ocrAppKey), 'app-key-1');

    // 未配置的键读 null。
    expect(await repo.getValue(AiSettingsKeys.llmEnabled), isNull);
  });

  test('ChatRole 枚举 code/fromCode 往返', () async {
    for (final r in ChatRole.values) {
      expect(ChatRole.fromCode(r.code), r);
    }
    expect(() => ChatRole.fromCode('robot'), throwsFormatException);
  });
}
