import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/data/models/chat_message.dart';
import 'package:plai/data/models/chat_session.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/data/repositories/chat_repository.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/features/ai/ai_page.dart';
import 'package:plai/features/ai/ai_providers.dart';
import 'package:plai/features/schedule/schedule_providers.dart';
import 'package:plai/features/settings/settings_providers.dart';
import 'package:plai/services/ai/llm_client.dart';
import 'package:plai/services/ai/models/ai_message.dart';

/// 内存版 IChatRepository。
class FakeChatRepository implements IChatRepository {
  final Map<int, ChatSession> _sessions = <int, ChatSession>{};
  final Map<int, List<ChatMessage>> _messages = <int, List<ChatMessage>>{};
  int _nextSession = 1;
  int _nextMessage = 1;

  int get sessionCount => _sessions.length;

  List<ChatMessage> messagesOf(int sessionId) =>
      List<ChatMessage>.of(_messages[sessionId] ?? const <ChatMessage>[]);

  /// 预置一个会话 + 若干消息，返回会话。
  ChatSession seedSession({
    required String title,
    List<(ChatRole, String)> turns = const [],
    DateTime? lastActiveAt,
    bool pinned = false,
  }) {
    final int id = _nextSession++;
    final ChatSession session = ChatSession(
      id: id,
      title: title,
      pinned: pinned,
      lastActiveAt: lastActiveAt ?? DateTime.now(),
    );
    _sessions[id] = session;
    final List<ChatMessage> list = <ChatMessage>[];
    for (final (ChatRole role, String content) in turns) {
      list.add(_makeMessage(id, role, content));
    }
    _messages[id] = list;
    return session;
  }

  ChatMessage _makeMessage(int sessionId, ChatRole role, String content) {
    final ChatMessage m = ChatMessage(
      id: _nextMessage,
      sessionId: sessionId,
      role: role,
      content: content,
      createdAt: DateTime.now(),
    );
    _nextMessage++;
    return m;
  }

  @override
  Future<List<ChatSession>> listSessions() async {
    final List<ChatSession> list = _sessions.values.toList()
      ..sort((ChatSession a, ChatSession b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return b.lastActiveAt.compareTo(a.lastActiveAt);
      });
    return list;
  }

  @override
  Future<ChatSession?> getSessionById(int id) async => _sessions[id];

  @override
  Future<int> createSession({String title = ''}) async {
    final int id = _nextSession++;
    _sessions[id] = ChatSession(id: id, title: title);
    _messages[id] = <ChatMessage>[];
    return id;
  }

  @override
  Future<int> renameSession(int id, String title) async {
    final ChatSession? s = _sessions[id];
    if (s == null) return 0;
    _sessions[id] = s.copyWith(title: title);
    return 1;
  }

  @override
  Future<int> setPinned(int id, bool pinned) async {
    final ChatSession? s = _sessions[id];
    if (s == null) return 0;
    _sessions[id] = s.copyWith(pinned: pinned);
    return 1;
  }

  @override
  Future<int> touchSession(int id) async {
    final ChatSession? s = _sessions[id];
    if (s == null) return 0;
    _sessions[id] = s.copyWith(lastActiveAt: DateTime.now());
    return 1;
  }

  @override
  Future<int> deleteSession(int id) async {
    _sessions.remove(id);
    _messages.remove(id);
    return 1;
  }

  @override
  Future<List<ChatMessage>> messagesFor(int sessionId) async =>
      List<ChatMessage>.of(_messages[sessionId] ?? const <ChatMessage>[]);

  @override
  Future<int> appendMessage(ChatMessage message) async {
    final ChatMessage m = _makeMessage(
      message.sessionId,
      message.role,
      message.content,
    ).copyWith(hasContext: message.hasContext);
    (_messages[message.sessionId] ??= <ChatMessage>[]).add(m);
    return m.id!;
  }

  @override
  Future<int> updateMessageContent(int id, String content) async {
    for (final List<ChatMessage> list in _messages.values) {
      for (int i = 0; i < list.length; i++) {
        if (list[i].id == id) {
          list[i] = list[i].copyWith(content: content);
          return 1;
        }
      }
    }
    return 0;
  }
}

/// 内存版 ISettingsRepository。
class FakeSettingsRepository implements ISettingsRepository {
  FakeSettingsRepository([Map<String, String>? seed])
      : _map = <String, String>{...?seed};

  final Map<String, String> _map;

  @override
  Future<String?> getValue(String key) async => _map[key];

  @override
  Future<void> setValue(String key, String value) async {
    _map[key] = value;
  }

  @override
  Future<void> setAll(Map<String, String> entries) async {
    _map.addAll(entries);
  }

  @override
  Future<Map<String, String>> getAll() async => Map.of(_map);

  @override
  Future<void> remove(String key) async {
    _map.remove(key);
  }
}

/// 假 LLM：不发网络，把收到的 wire 记下来并推一段固定回复。
class FakeLlmClient extends LlmClient {
  FakeLlmClient({
    required super.baseUrl,
    super.apiKey = '',
    required super.model,
    this.reply = '已收到。',
    this.onWire,
  });

  final String reply;
  final void Function(List<AiMessage> wire)? onWire;

  @override
  Future<LlmChatResult> chatStream({
    required List<AiMessage> messages,
    List<Map<String, dynamic>>? tools,
    Object? toolChoice,
    bool jsonMode = false,
    double? temperature = 0.3,
    Duration? timeout,
    void Function(LlmDelta delta)? onDelta,
  }) async {
    onWire?.call(messages);
    onDelta?.call(LlmDelta(contentDelta: reply));
    return LlmChatResult(content: reply, finishReason: 'stop', model: model);
  }
}

void main() {
  Widget harness({
    required FakeChatRepository chat,
    FakeSettingsRepository? settings,
    List<TodayCourse> courses = const <TodayCourse>[],
    List<Task> tasks = const <Task>[],
    void Function(List<AiMessage>)? onWire,
    String reply = '已收到。',
  }) {
    return ProviderScope(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        settingsRepositoryProvider.overrideWithValue(
            settings ?? FakeSettingsRepository()),
        llmConfigProvider.overrideWith((ref) async => const LlmConfig(
              enabled: true,
              baseUrl: 'https://api.example.com/v1',
              apiKey: 'k',
              model: 'm',
            )),
        llmClientFactoryProvider.overrideWith(
          (ref) => ({
                required String baseUrl,
                String apiKey = '',
                required String model,
              }) =>
                  FakeLlmClient(
                    baseUrl: baseUrl,
                    apiKey: apiKey,
                    model: model,
                    reply: reply,
                    onWire: onWire,
                  ),
        ),
        todayCoursesProvider.overrideWith((ref) async => courses),
        tasksProvider.overrideWith((ref) async => tasks),
      ],
      child: const MaterialApp(home: AiPage()),
    );
  }

  testWidgets('AI：空态 + 知情对话框一次 + 发送自动建会话并流式入流落库',
      (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeSettingsRepository settings = FakeSettingsRepository();
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(chat: chat, settings: settings, reply: '已收到你的消息。'),
    );
    await tester.pumpAndSettle();

    // 空态引导。
    expect(find.text('开始一段对话吧'), findsOneWidget);
    expect(find.text('关于 AI 对话'), findsNothing);

    // 输入并发送 → 先弹知情对话框。
    await tester.enterText(find.byType(TextField), '你好 Plai');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(find.text('关于 AI 对话'), findsOneWidget);
    await tester.tap(find.text('开始使用'));
    await tester.pumpAndSettle();

    // 自动创建会话：标题来自首条消息、user+assistant 两条已落库。
    expect(chat.sessionCount, 1);
    final ChatSession only = (await chat.listSessions()).single;
    expect(only.title, '你好 Plai');
    final List<ChatMessage> stored = chat.messagesOf(only.id!);
    expect(stored.length, 2);
    expect(stored[0].role, ChatRole.user);
    expect(stored[0].content, '你好 Plai');
    expect(stored[0].hasContext, isFalse);
    expect(stored[1].role, ChatRole.assistant);
    expect(stored[1].content, '已收到你的消息。');

    // UI 显示助手回复；知情提示已落键（一次性）。
    expect(find.text('已收到你的消息。'), findsOneWidget);
    expect(await settings.getValue('ai.onboarded'), '1');

    // 第二次发送不再弹对话框。
    await tester.enterText(find.byType(TextField), '再说一遍');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(find.text('关于 AI 对话'), findsNothing);
  });

  testWidgets('AI：勾选上下文 → 注入今日课表与日程，历史只存原文',
      (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final DateTime now = DateTime.now();
    const TodayCourse today = TodayCourse(
      course: Course(
        name: '高等数学',
        semesterId: 1,
        location: '教一101',
        weekday: 1,
        startPeriod: 1,
        endPeriod: 2,
      ),
      week: 1,
      startTime: TimeOfDay(hour: 8, minute: 0),
      endTime: TimeOfDay(hour: 9, minute: 40),
    );
    final Task task = Task(
      title: '交作业',
      type: TaskType.scheduled,
      dueDate: DateTime(now.year, now.month, now.day),
    );

    final List<AiMessage> capturedWire = <AiMessage>[];
    await tester.pumpWidget(
      harness(
        chat: chat,
        settings: FakeSettingsRepository(<String, String>{'ai.onboarded': '1'}),
        courses: <TodayCourse>[today],
        tasks: <Task>[task],
        onWire: capturedWire.addAll,
      ),
    );
    await tester.pumpAndSettle();

    // 勾选上下文（默认不勾）。
    await tester.tap(find.byType(Checkbox));
    await tester.pump();

    await tester.enterText(find.byType(TextField), '看看今天的安排');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    // wire 最后一条 user 携带注入内容。
    expect(capturedWire, isNotEmpty);
    final AiMessage lastUser =
        capturedWire.lastWhere((AiMessage m) => m.role == AiRole.user);
    expect(lastUser.text, contains('看看今天的安排'));
    expect(lastUser.text, contains('【今日课表】'));
    expect(lastUser.text, contains('高等数学'));
    expect(lastUser.text, contains('【今日日程】'));
    expect(lastUser.text, contains('交作业'));

    // 历史只存原文：不带上下文，但 hasContext=true。
    final int sessionId = (await chat.listSessions()).single.id!;
    final List<ChatMessage> stored = chat.messagesOf(sessionId);
    final ChatMessage userMsg =
        stored.singleWhere((ChatMessage m) => m.role == ChatRole.user);
    expect(userMsg.content, '看看今天的安排');
    expect(userMsg.content.contains('【今日课表】'), isFalse);
    expect(userMsg.hasContext, isTrue);
  });

  testWidgets('AI：历史会话抽屉切换会话显示对应消息', (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    chat.seedSession(
      title: '你好',
      turns: const [(ChatRole.user, 'hi'), (ChatRole.assistant, 'hello world')],
    );
    chat.seedSession(
      title: '第二会话',
      turns: const [
        (ChatRole.user, '早'),
        (ChatRole.assistant, '早安世界'),
      ],
      lastActiveAt: DateTime.now().subtract(const Duration(hours: 1)),
    );
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        chat: chat,
        settings: FakeSettingsRepository(<String, String>{'ai.onboarded': '1'}),
      ),
    );
    await tester.pumpAndSettle();

    // 进入自动选中最近会话（第一个）。
    expect(find.text('hello world'), findsOneWidget);

    // 打开抽屉，列出历史，切到「第二会话」。
    // 注意：抽屉开启时 AppBar 仍显示当前会话标题「你好」（背板不 offstage），
    // 故断言只针对唯一文本的「第二会话」。
    await tester.tap(find.byTooltip('历史对话'));
    await tester.pumpAndSettle();
    expect(find.text('第二会话'), findsOneWidget);

    await tester.tap(find.text('第二会话'));
    await tester.pumpAndSettle();
    expect(find.text('早安世界'), findsOneWidget);
    expect(find.text('hello world'), findsNothing);
  });
}
