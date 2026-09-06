import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/models/chat_message.dart';
import 'package:plai/data/models/chat_session.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/data/repositories/chat_repository.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:plai/features/ai/ai_page.dart';
import 'package:plai/features/ai/ai_providers.dart';
import 'package:plai/features/schedule/schedule_providers.dart';
import 'package:plai/features/settings/settings_providers.dart';
import 'package:plai/services/ai/llm_client.dart';
import 'package:plai/services/ai/models/ai_message.dart';
import 'package:plai/services/ai/models/ai_tool.dart';
import 'package:plai/services/notifications/notification_providers.dart';
import 'package:plai/services/notifications/notification_scheduler.dart';

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
    ).copyWith(
      hasContext: message.hasContext,
      attachments: message.attachments,
      toolRecords: message.toolRecords,
    );
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

/// 内存版 ITaskRepository（S7 写工具验证用）。
class FakeTaskRepository implements ITaskRepository {
  final Map<int, Task> _tasks = <int, Task>{};
  final Map<int, Set<DateTime>> _dailyLogs = <int, Set<DateTime>>{};
  int _next = 1;

  int get taskCount => _tasks.length;

  @override
  Future<List<Task>> getTasks({
    TaskType? type,
    bool? completed,
    DateTime? from,
    DateTime? to,
  }) async =>
      _tasks.values
          .where((Task t) =>
              (type == null || t.type == type) &&
              (completed == null || t.completed == completed))
          .toList();

  @override
  Future<Task?> getTaskById(int id) async => _tasks[id];

  @override
  Future<int> insertTask(Task task) async {
    final int id = _next++;
    _tasks[id] = task.copyWith(id: id);
    return id;
  }

  @override
  Future<int> updateTask(Task task) async {
    final int? id = task.id;
    if (id == null || !_tasks.containsKey(id)) return 0;
    _tasks[id] = task;
    return 1;
  }

  @override
  Future<int> deleteTask(int id) async => _tasks.remove(id) == null ? 0 : 1;

  @override
  Future<int> setCompleted(int id, bool completed) async {
    final Task? t = _tasks[id];
    if (t == null) return 0;
    _tasks[id] = t.copyWith(
      completed: completed,
      completedAt: completed ? DateTime.now() : null,
    );
    return 1;
  }

  @override
  Future<void> markDailyCompleted(int taskId, DateTime date) async =>
      (_dailyLogs[taskId] ??= <DateTime>{}).add(
        DateTime(date.year, date.month, date.day),
      );

  @override
  Future<void> clearDailyCompleted(int taskId, DateTime date) async =>
      _dailyLogs[taskId]?.remove(DateTime(date.year, date.month, date.day));

  @override
  Future<bool> isDailyCompleted(int taskId, DateTime date) async =>
      _dailyLogs[taskId]
          ?.contains(DateTime(date.year, date.month, date.day)) ??
      false;

  @override
  Future<List<DateTime>> dailyLogsFor(int taskId) async {
    final List<DateTime> logs = _dailyLogs[taskId]?.toList() ?? <DateTime>[];
    logs.sort();
    return logs;
  }
}

/// 假提醒调度器：no-op（不触通知插件）。
class FakeScheduler extends NotificationScheduler {
  FakeScheduler()
      : super(
          TimetableRepository(AppDatabase.instance),
          TaskRepository(AppDatabase.instance),
          SettingsRepository(AppDatabase.instance),
        );

  @override
  Future<void> scheduleTaskReminder(Task task) async {}
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
///
/// [turns] 提供逐轮脚本（第 N 次 chatStream 返回 turns[N]，含工具调用轮）；
/// 用尽后回退固定文本 [reply]。
class FakeLlmClient extends LlmClient {
  FakeLlmClient({
    required super.baseUrl,
    super.apiKey = '',
    required super.model,
    this.turns = const <LlmChatResult>[],
    this.reply = '已收到。',
    this.onWire,
    this.onRequest,
  });

  /// 逐轮脚本；空 = 每轮都回固定文本。
  final List<LlmChatResult> turns;

  /// 无脚本轮时的固定文本回复。
  final String reply;

  /// 每轮记录收到的 wire。
  final void Function(List<AiMessage> wire)? onWire;

  /// 每轮记录收到的 tools（null = 本次请求未提供工具）。
  final void Function(List<Map<String, dynamic>>? tools)? onRequest;

  int _round = 0;

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
    onRequest?.call(tools);
    onWire?.call(messages);
    final LlmChatResult result = _round < turns.length
        ? turns[_round++]
        : LlmChatResult(content: reply, finishReason: 'stop', model: model);
    final String? text = result.content;
    if (text != null && text.isNotEmpty) {
      onDelta?.call(LlmDelta(contentDelta: text));
    }
    return result;
  }
}

void main() {
  Widget harness({
    required FakeChatRepository chat,
    FakeSettingsRepository? settings,
    FakeTaskRepository? taskRepo,
    List<TodayCourse> courses = const <TodayCourse>[],
    List<Task> tasks = const <Task>[],
    List<TodayCourse> Function(DateTime day)? dayCourses,
    void Function(List<AiMessage>)? onWire,
    void Function(List<Map<String, dynamic>>? tools)? onRequest,
    List<LlmChatResult> turns = const <LlmChatResult>[],
    String reply = '已收到。',
  }) {
    return ProviderScope(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        settingsRepositoryProvider.overrideWithValue(
            settings ?? FakeSettingsRepository()),
        taskRepositoryProvider
            .overrideWithValue(taskRepo ?? FakeTaskRepository()),
        notificationSchedulerProvider.overrideWithValue(FakeScheduler()),
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
                    turns: turns,
                    onWire: onWire,
                    onRequest: onRequest,
                  ),
        ),
        todayCoursesProvider.overrideWith((ref) async => courses),
        tasksProvider.overrideWith((ref) async => tasks),
        if (dayCourses != null)
          dayCoursesProvider.overrideWith(
              (ref, DateTime day) async => dayCourses(day)),
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
    expect(find.widgetWithText(TextField, '输入消息'), findsOneWidget);

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

    // 打开历史面板（推挤式），列出历史，切到「第二会话」。
    // 注意：面板开启时 AppBar 仍显示当前会话标题「你好」，
    // 故断言只针对唯一文本的「第二会话」。
    await tester.tap(find.byTooltip('历史对话'));
    await tester.pumpAndSettle();
    expect(find.text('新建对话'), findsOneWidget);
    expect(find.text('第二会话'), findsOneWidget);

    await tester.tap(find.text('第二会话'));
    await tester.pumpAndSettle();
    expect(find.text('早安世界'), findsOneWidget);
    expect(find.text('hello world'), findsNothing);
  });

  testWidgets('AI：历史面板点右侧残留区收起，主界面回位',
      (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    chat.seedSession(
      title: '你好',
      turns: const [(ChatRole.user, 'hi'), (ChatRole.assistant, 'hello world')],
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

    // 打开面板 → 点右侧残留区（屏宽 800，面板占 656）→ 收起。
    await tester.tap(find.byTooltip('历史对话'));
    await tester.pumpAndSettle();
    expect(find.text('新建对话'), findsOneWidget);
    await tester.tapAt(const Offset(760, 700));
    await tester.pumpAndSettle();
    expect(find.text('新建对话'), findsNothing);
    expect(find.text('hello world'), findsOneWidget);
  });

  testWidgets('AI：S6 工具循环——模型调只读工具本地执行回传并落库',
      (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final DateTime tomorrow = DateTime.now().add(const Duration(days: 1));
    final DateTime tomorrowDay =
        DateTime(tomorrow.year, tomorrow.month, tomorrow.day);
    final String tomorrowStr = '${tomorrow.year.toString().padLeft(4, '0')}-'
        '${tomorrow.month.toString().padLeft(2, '0')}-'
        '${tomorrow.day.toString().padLeft(2, '0')}';

    const TodayCourse tomorrowCourse = TodayCourse(
      course: Course(
        name: '高等数学',
        semesterId: 1,
        location: '教一101',
        weekday: 2,
        startPeriod: 1,
        endPeriod: 2,
      ),
      week: 1,
      startTime: TimeOfDay(hour: 8, minute: 0),
      endTime: TimeOfDay(hour: 9, minute: 40),
    );

    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'c1',
            name: 'get_day_schedule',
            argumentsJson: '{"date": "$tomorrowStr"}',
          ),
        ],
        finishReason: 'tool_calls',
      ),
      const LlmChatResult(content: '明天有 1 节高等数学。', finishReason: 'stop'),
    ];
    final List<List<AiMessage>> wires = <List<AiMessage>>[];
    final List<List<Map<String, dynamic>>?> requests =
        <List<Map<String, dynamic>>?>[];

    await tester.pumpWidget(
      harness(
        chat: chat,
        settings:
            FakeSettingsRepository(<String, String>{'ai.onboarded': '1'}),
        turns: turns,
        onWire: wires.add,
        onRequest: requests.add,
        dayCourses: (DateTime day) => day == tomorrowDay
            ? const <TodayCourse>[tomorrowCourse]
            : const <TodayCourse>[],
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '我明天有几堂课');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    // 两轮请求：第一轮带工具定义；第二轮 wire 含 assistant 工具调用与 tool 结果。
    expect(requests.length, 2);
    expect(requests[0], isNotNull);
    expect(
      wires[1].any((AiMessage m) =>
          m.role == AiRole.tool &&
          m.toolCallId == 'c1' &&
          (m.text?.contains('高等数学') ?? false)),
      isTrue,
    );

    // 落库：user / assistant(工具轮, 无正文) / tool(结果) / assistant(最终)。
    final int sessionId = (await chat.listSessions()).single.id!;
    final List<ChatMessage> stored = chat.messagesOf(sessionId);
    expect(stored.length, 4);
    expect(stored[0].role, ChatRole.user);
    expect(stored[1].role, ChatRole.assistant);
    expect(stored[1].content, isEmpty);
    expect(stored[1].toolRecords.first['type'], 'tool_calls');
    expect(stored[2].role, ChatRole.tool);
    expect(stored[2].content, contains('高等数学'));
    expect(stored[2].toolRecords.first['tool_call_id'], 'c1');
    expect(stored[3].role, ChatRole.assistant);
    expect(stored[3].content, '明天有 1 节高等数学。');

    // UI：只显示最终回答；查询过程（小字行/工具轮消息）不渲染。
    expect(find.text('明天有 1 节高等数学。'), findsOneWidget);
    expect(find.textContaining('查询了'), findsNothing);
    expect(find.text(stored[2].content), findsNothing);
  });

  testWidgets('AI：S6 轮次上限——达上限后的请求不再提供工具',
      (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final List<LlmChatResult> turns = <LlmChatResult>[
      for (int i = 0; i < maxToolRounds; i++)
        LlmChatResult(
          toolCalls: <AiToolCall>[
            AiToolCall(id: 'c$i', name: 'get_date_info', argumentsJson: '{}'),
          ],
          finishReason: 'tool_calls',
        ),
      const LlmChatResult(content: '查询完毕。', finishReason: 'stop'),
    ];
    final List<List<Map<String, dynamic>>?> requests =
        <List<Map<String, dynamic>>?>[];

    await tester.pumpWidget(
      harness(
        chat: chat,
        settings:
            FakeSettingsRepository(<String, String>{'ai.onboarded': '1'}),
        turns: turns,
        onRequest: requests.add,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '今天几号');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    // 前 maxToolRounds 轮带工具，收尾轮不带。
    expect(requests.length, maxToolRounds + 1);
    for (int i = 0; i < maxToolRounds; i++) {
      expect(requests[i], isNotNull);
    }
    expect(requests[maxToolRounds], isNull);

    // 落库：1 user + maxToolRounds×(assistant+tool) + 1 assistant。
    final int sessionId = (await chat.listSessions()).single.id!;
    expect(chat.messagesOf(sessionId).length, 2 + maxToolRounds * 2);
    expect(find.text('查询完毕。'), findsOneWidget);
  });

  testWidgets('AI：S7 门控——写开关关闭时请求不含写工具',
      (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final List<List<Map<String, dynamic>>?> requests =
        <List<Map<String, dynamic>>?>[];

    await tester.pumpWidget(
      harness(
        chat: chat,
        settings:
            FakeSettingsRepository(<String, String>{'ai.onboarded': '1'}),
        onRequest: requests.add,
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    expect(requests, hasLength(1));
    final List<Map<String, dynamic>> tools = requests[0]!;
    expect(tools.any((Map<String, dynamic> t) =>
        t['function']['name'] == 'create_task'), isFalse);
    expect(tools.any((Map<String, dynamic> t) =>
        t['function']['name'] == 'set_task_completed'), isFalse);
    expect(tools.any((Map<String, dynamic> t) =>
        t['function']['name'] == 'get_day_schedule'), isTrue);
  });

  testWidgets('AI：S7 门控——写开关开启时请求包含写工具',
      (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final List<List<Map<String, dynamic>>?> requests =
        <List<Map<String, dynamic>>?>[];

    await tester.pumpWidget(
      harness(
        chat: chat,
        settings: FakeSettingsRepository(<String, String>{
          'ai.onboarded': '1',
          'ai.write_enabled': 'true',
        }),
        onRequest: requests.add,
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    expect(requests, hasLength(1));
    final List<Map<String, dynamic>> tools = requests[0]!;
    expect(tools.any((Map<String, dynamic> t) =>
        t['function']['name'] == 'create_task'), isTrue);
    expect(tools.any((Map<String, dynamic> t) =>
        t['function']['name'] == 'set_task_completed'), isTrue);
  });

  testWidgets('AI：S7 写工具——确认后执行 create_task 并回传结果',
      (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final DateTime tomorrow = DateTime.now().add(const Duration(days: 1));
    final String tomorrowStr = '${tomorrow.year.toString().padLeft(4, '0')}-'
        '${tomorrow.month.toString().padLeft(2, '0')}-'
        '${tomorrow.day.toString().padLeft(2, '0')}';
    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'w1',
            name: 'create_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'title': '交高数作业',
              'type': 'todo',
              'due_date': tomorrowStr,
            }),
          ),
        ],
        finishReason: 'tool_calls',
      ),
      const LlmChatResult(content: '已为你新建日程。', finishReason: 'stop'),
    ];

    await tester.pumpWidget(
      harness(
        chat: chat,
        taskRepo: taskRepo,
        settings: FakeSettingsRepository(<String, String>{
          'ai.onboarded': '1',
          'ai.write_enabled': 'true',
        }),
        turns: turns,
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '帮我建个明天交高数作业的待办');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    // 弹窗等待期间占位行有转圈，不能 pumpAndSettle，用固定时长推进滑入动画。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 确认面板出现，描述人类可读。
    expect(find.text('AI 请求修改数据'), findsOneWidget);
    expect(find.textContaining('新建待办任务「交高数作业」'), findsOneWidget);

    // 确认执行。
    await tester.tap(find.text('执行选中项（1）'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    // 任务真正落库。
    expect(taskRepo.taskCount, 1);
    final Task created = (await taskRepo.getTasks()).single;
    expect(created.title, '交高数作业');
    expect(created.type, TaskType.todo);
    expect(created.dueDate.day, tomorrow.day);

    // tool 消息回传 created；面板关闭；最终回答显示。
    final int sessionId = (await chat.listSessions()).single.id!;
    final ChatMessage toolMsg =
        chat.messagesOf(sessionId).firstWhere((ChatMessage m) => m.role == ChatRole.tool);
    expect(toolMsg.content, contains('"created"'));
    expect(find.text('AI 请求修改数据'), findsNothing);
    expect(find.text('已为你新建日程。'), findsOneWidget);
  });

  testWidgets('AI：S7 写工具——全部跳过后不执行且回传 skipped',
      (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final DateTime tomorrow = DateTime.now().add(const Duration(days: 1));
    final String tomorrowStr = '${tomorrow.year.toString().padLeft(4, '0')}-'
        '${tomorrow.month.toString().padLeft(2, '0')}-'
        '${tomorrow.day.toString().padLeft(2, '0')}';
    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'w1',
            name: 'create_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'title': '不要建这条',
              'type': 'todo',
              'due_date': tomorrowStr,
            }),
          ),
        ],
        finishReason: 'tool_calls',
      ),
      const LlmChatResult(content: '好的，没有创建。', finishReason: 'stop'),
    ];

    await tester.pumpWidget(
      harness(
        chat: chat,
        taskRepo: taskRepo,
        settings: FakeSettingsRepository(<String, String>{
          'ai.onboarded': '1',
          'ai.write_enabled': 'true',
        }),
        turns: turns,
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '帮我建个待办');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    // 同上：占位行转圈期间用固定时长推进弹窗动画。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('AI 请求修改数据'), findsOneWidget);
    await tester.tap(find.text('全部跳过'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    // 任务未创建；tool 消息回传 skipped。
    expect(taskRepo.taskCount, 0);
    final int sessionId = (await chat.listSessions()).single.id!;
    final ChatMessage toolMsg =
        chat.messagesOf(sessionId).firstWhere((ChatMessage m) => m.role == ChatRole.tool);
    expect(toolMsg.content, contains('"skipped"'));
    expect(find.text('好的，没有创建。'), findsOneWidget);
  });
}
