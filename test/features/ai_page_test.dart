import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/models/chat_message.dart';
import 'package:plai/data/models/chat_session.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/holiday.dart';
import 'package:plai/data/models/period.dart';
import 'package:plai/data/models/semester.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/data/repositories/chat_repository.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:plai/features/ai/ai_page.dart';
import 'package:plai/features/ai/ai_providers.dart';
import 'package:plai/features/schedule/schedule_providers.dart';
import 'package:plai/features/settings/settings_providers.dart';
import 'package:plai/features/timetable/timetable_providers.dart'
    hide settingsRepositoryProvider;
import 'package:plai/services/ai/llm_client.dart';
import 'package:plai/services/ai/models/ai_message.dart';
import 'package:plai/services/ai/models/ai_tool.dart';
import 'package:plai/services/notifications/class_reminder_planner.dart';
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

  /// 预置任务（id 取 task.id）。
  void seed(Task task) {
    final int? id = task.id;
    assert(id != null, 'seed 任务必须带 id');
    _tasks[id!] = task;
    if (id >= _next) _next = id + 1;
  }

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

  @override
  Future<void> rescheduleAll({List<ClassReminderPlan>? classPlans}) async {}
}

/// 内存版 ITimetableRepository（update_course 验证用，未触路径抛未实现）。
class FakeTimetableRepository implements ITimetableRepository {
  final Map<int, Course> _courses = <int, Course>{};
  final List<Semester> _semesters = <Semester>[];
  int _nextCourse = 1;

  int get courseCount => _courses.length;

  void seedCourse(Course course) {
    final int? id = course.id;
    assert(id != null, 'seed 课程必须带 id');
    _courses[id!] = course;
    if (id >= _nextCourse) _nextCourse = id + 1;
  }

  /// 预置学期（create_course 的当前学期判定用）。
  void seedSemester(Semester semester) => _semesters.add(semester);

  @override
  Future<Course?> getCourseById(int id) async => _courses[id];

  @override
  Future<int> updateCourse(Course course) async {
    final int? id = course.id;
    if (id == null || !_courses.containsKey(id)) return 0;
    _courses[id] = course;
    return 1;
  }

  @override
  Future<List<Course>> getAllCourses() async =>
      List<Course>.of(_courses.values);

  @override
  Future<List<Course>> getCourses(int semesterId) async => _courses.values
      .where((Course c) => c.semesterId == semesterId)
      .toList();

  @override
  Future<List<Course>> getCoursesByWeekday(int semesterId, int weekday) async =>
      _courses.values
          .where((Course c) =>
              c.semesterId == semesterId && c.weekday == weekday)
          .toList();

  @override
  Future<int> insertCourse(Course course) async {
    final int id = _nextCourse++;
    _courses[id] = course.copyWith(id: id);
    return id;
  }

  @override
  Future<int> deleteCourse(int id) async => _courses.remove(id) == null ? 0 : 1;

  @override
  Future<List<Semester>> getSemesters() async =>
      List<Semester>.of(_semesters);

  @override
  Future<List<Period>> getPeriods() async => const <Period>[];

  @override
  Future<List<Holiday>> getHolidays(
          {int? courseId, DateTime? from, DateTime? to}) async =>
      const <Holiday>[];

  @override
  Future<void> replacePeriods(List<Period> periods) async {}

  @override
  Future<Semester?> getSemesterById(int id) => throw UnimplementedError();
  @override
  Future<int> insertSemester(Semester semester) => throw UnimplementedError();
  @override
  Future<int> updateSemester(Semester semester) => throw UnimplementedError();
  @override
  Future<int> deleteSemester(int id) => throw UnimplementedError();
  @override
  Future<int> insertPeriod(Period period) => throw UnimplementedError();
  @override
  Future<int> updatePeriod(Period period) => throw UnimplementedError();
  @override
  Future<int> deletePeriod(int id) => throw UnimplementedError();
  @override
  Future<int> insertHoliday(Holiday holiday) => throw UnimplementedError();
  @override
  Future<int> updateHoliday(Holiday holiday) => throw UnimplementedError();
  @override
  Future<int> deleteHoliday(int id) => throw UnimplementedError();
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
    FakeTimetableRepository? timetableRepo,
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
        if (timetableRepo != null)
          timetableRepositoryProvider.overrideWithValue(timetableRepo),
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

  testWidgets('AI：键盘弹出时消息区贴住输入框（reverse 列表零误差）',
      (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final List<(ChatRole, String)> turns = <(ChatRole, String)>[
      for (int i = 0; i < 30; i++) ...[
        (ChatRole.user, '消息$i'),
        (ChatRole.assistant, '回复$i，这是一条足够长的回复内容用于撑起滚动区域。'),
      ],
    ];
    chat.seedSession(title: '长对话', turns: turns);
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

    final ListView list = tester.widget(find.byType(ListView));
    final ScrollController ctl = list.controller!;
    await tester.pumpAndSettle();
    // reverse 列表：offset 0 = 最新消息贴底。
    expect(ctl.position.pixels, 0);

    // 模拟键盘弹出（insets bottom = 400）：视口收缩，最新消息无需滚动
    // 依旧贴住输入框上方（offset 保持 0）。
    tester.view.viewInsets = const FakeViewPadding(bottom: 400);
    await tester.pumpAndSettle();

    expect(ctl.position.pixels, 0);
    expect(find.text('消息29'), findsOneWidget);
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
              'remind_minutes': 10,
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
    expect(created.remindOffsetMin, 10); // 提醒要求进字段而非描述
    expect(created.description, isNot(contains('提醒')));

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

  testWidgets('AI：S7 防重——相同写调用重复发起不二次弹窗、不重复执行',
      (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final DateTime tomorrow = DateTime.now().add(const Duration(days: 1));
    final String tomorrowStr = '${tomorrow.year.toString().padLeft(4, '0')}-'
        '${tomorrow.month.toString().padLeft(2, '0')}-'
        '${tomorrow.day.toString().padLeft(2, '0')}';
    final Map<String, dynamic> args = <String, dynamic>{
      'title': '交高数作业',
      'type': 'todo',
      'due_date': tomorrowStr,
    };
    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
              id: 'w1',
              name: 'create_task',
              argumentsJson: jsonEncode(args)),
        ],
        finishReason: 'tool_calls',
      ),
      // 模型重复发起完全相同的调用（异常行为）。
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
              id: 'w2',
              name: 'create_task',
              argumentsJson: jsonEncode(args)),
        ],
        finishReason: 'tool_calls',
      ),
      const LlmChatResult(content: '已创建。', finishReason: 'stop'),
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 第一次弹窗 → 确认执行。
    expect(find.text('AI 请求修改数据'), findsOneWidget);
    await tester.tap(find.text('执行选中项（1）'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    // 第二次相同调用不弹窗、不重复建任务。
    expect(find.text('AI 请求修改数据'), findsNothing);
    expect(taskRepo.taskCount, 1);

    // 两条 tool 消息：第一条 created，第二条 skipped（防重）。
    final int sessionId = (await chat.listSessions()).single.id!;
    final List<ChatMessage> toolMsgs = chat
        .messagesOf(sessionId)
        .where((ChatMessage m) => m.role == ChatRole.tool)
        .toList();
    expect(toolMsgs, hasLength(2));
    expect(toolMsgs[0].content, contains('"created"'));
    expect(toolMsgs[1].content, contains('"skipped"'));
    expect(find.text('已创建。'), findsOneWidget);
  });

  testWidgets('AI：S7 参数自纠——无效调用不弹窗直接报错，修正后才确认一次',
      (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final DateTime tomorrow = DateTime.now().add(const Duration(days: 1));
    final String tomorrowStr = '${tomorrow.year.toString().padLeft(4, '0')}-'
        '${tomorrow.month.toString().padLeft(2, '0')}-'
        '${tomorrow.day.toString().padLeft(2, '0')}';
    final List<LlmChatResult> turns = <LlmChatResult>[
      // 第一次：缺 due_date（参数无效）→ 不弹窗，直接 error。
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'w1',
            name: 'create_task',
            argumentsJson: jsonEncode(<String, dynamic>{'title': '交高数作业'}),
          ),
        ],
        finishReason: 'tool_calls',
      ),
      // 第二次：补全参数 → 弹窗确认一次。
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'w2',
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
      const LlmChatResult(content: '已创建。', finishReason: 'stop'),
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 第一次调用参数无效：不弹窗，直接进入第二次（此时弹窗出现）。
    final int sessionId = (await chat.listSessions()).single.id!;
    expect(find.text('AI 请求修改数据'), findsOneWidget);

    await tester.tap(find.text('执行选中项（1）'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    // 只创建一条；第一次调用回 error、第二次回 created。
    expect(taskRepo.taskCount, 1);
    final List<ChatMessage> toolMsgs = chat
        .messagesOf(sessionId)
        .where((ChatMessage m) => m.role == ChatRole.tool)
        .toList();
    expect(toolMsgs, hasLength(2));
    expect(toolMsgs[0].content, contains('"error"'));
    expect(toolMsgs[1].content, contains('"created"'));
  });

  testWidgets('AI：S7 修改日程——update_task 确认后按字段部分更新',
      (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final DateTime due = DateTime.now().add(const Duration(days: 1));
    final DateTime newDue = DateTime.now().add(const Duration(days: 3));
    final String newDueStr = '${newDue.year.toString().padLeft(4, '0')}-'
        '${newDue.month.toString().padLeft(2, '0')}-'
        '${newDue.day.toString().padLeft(2, '0')}';
    taskRepo.seed(Task(
      id: 1,
      title: '交高数作业',
      type: TaskType.todo,
      dueDate: due,
    ));

    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'u1',
            name: 'update_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'task_id': 1,
              'due_date': newDueStr,
              'priority': 'urgent',
            }),
          ),
        ],
        finishReason: 'tool_calls',
      ),
      const LlmChatResult(content: '已修改。', finishReason: 'stop'),
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
    await tester.enterText(find.byType(TextField), '把交高数作业改到3天后');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 确认卡片显示改动前后对比。
    expect(find.text('AI 请求修改数据'), findsOneWidget);
    expect(find.textContaining('修改「交高数作业」'), findsOneWidget);
    expect(find.textContaining('优先级 → 紧急'), findsOneWidget);

    await tester.tap(find.text('执行选中项（1）'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    // 字段部分更新：日期与优先级变了，标题/类型保持。
    expect(taskRepo.taskCount, 1);
    final Task updated = (await taskRepo.getTasks()).single;
    expect(updated.title, '交高数作业');
    expect(updated.type, TaskType.todo);
    expect(_sameDayOf(updated.dueDate, newDue), isTrue);
    expect(updated.priority, Priority.urgent);
    expect(find.text('已修改。'), findsOneWidget);
  });

  testWidgets('AI：S7 修改课程——update_course 确认后更新并回传',
      (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTimetableRepository timetableRepo = FakeTimetableRepository();
    timetableRepo.seedCourse(const Course(
      id: 1,
      semesterId: 1,
      name: '高等数学',
      location: '教一101',
      weekday: 2,
      startPeriod: 1,
      endPeriod: 2,
      endWeek: 14,
    ));

    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'c1',
            name: 'update_course',
            argumentsJson: jsonEncode(<String, dynamic>{
              'course_id': 1,
              'location': '教二202',
              'end_week': 16,
            }),
          ),
        ],
        finishReason: 'tool_calls',
      ),
      const LlmChatResult(content: '已修改课程。', finishReason: 'stop'),
    ];

    await tester.pumpWidget(
      harness(
        chat: chat,
        timetableRepo: timetableRepo,
        settings: FakeSettingsRepository(<String, String>{
          'ai.onboarded': '1',
          'ai.write_enabled': 'true',
        }),
        turns: turns,
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '把高数换到教二202');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('AI 请求修改数据'), findsOneWidget);
    expect(find.textContaining('修改课程「高等数学」'), findsOneWidget);
    expect(find.textContaining('教室 → 教二202'), findsOneWidget);

    await tester.tap(find.text('执行选中项（1）'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(timetableRepo.courseCount, 1);
    final Course updated = (await timetableRepo.getAllCourses()).single;
    expect(updated.location, '教二202');
    expect(updated.endWeek, 16);
    expect(updated.name, '高等数学');
    expect(find.text('已修改课程。'), findsOneWidget);
  });

  testWidgets('AI：S8 批量草稿——一轮并行多条创建一次确认落库',
      (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final DateTime tomorrow = DateTime.now().add(const Duration(days: 1));
    final String tomorrowStr = '${tomorrow.year.toString().padLeft(4, '0')}-'
        '${tomorrow.month.toString().padLeft(2, '0')}-'
        '${tomorrow.day.toString().padLeft(2, '0')}';
    final List<LlmChatResult> turns = <LlmChatResult>[
      // 一条回复里并行发起两条 create_task（批量计划场景）。
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'b1',
            name: 'create_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'title': '周一开班会',
              'type': 'scheduled',
              'due_date': tomorrowStr,
              'due_time': '09:00',
            }),
          ),
          AiToolCall(
            id: 'b2',
            name: 'create_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'title': '周三交实验报告',
              'type': 'todo',
              'due_date': tomorrowStr,
            }),
          ),
        ],
        finishReason: 'tool_calls',
      ),
      const LlmChatResult(content: '已创建两条。', finishReason: 'stop'),
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
    await tester.enterText(find.byType(TextField), '帮我安排这两件事');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 一个面板列出两张草稿卡。
    expect(find.text('AI 请求修改数据'), findsOneWidget);
    expect(find.textContaining('新建定点日程「周一开班会」'), findsOneWidget);
    expect(find.textContaining('新建待办任务「周三交实验报告」'), findsOneWidget);
    expect(find.text('执行选中项（2）'), findsOneWidget);

    await tester.tap(find.text('执行选中项（2）'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    // 两条都落库；两条 tool 消息均 created。
    expect(taskRepo.taskCount, 2);
    final List<Task> tasks = await taskRepo.getTasks();
    expect(tasks.map((Task t) => t.title), containsAll(<String>[
      '周一开班会',
      '周三交实验报告',
    ]));
    final int sessionId = (await chat.listSessions()).single.id!;
    final List<ChatMessage> toolMsgs = chat
        .messagesOf(sessionId)
        .where((ChatMessage m) => m.role == ChatRole.tool)
        .toList();
    expect(toolMsgs, hasLength(2));
    expect(toolMsgs[0].content, contains('"created"'));
    expect(toolMsgs[1].content, contains('"created"'));
  });

  testWidgets('AI：S8 草稿编辑——确认面板内改标题后按新内容落库',
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
            id: 'e1',
            name: 'create_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'title': 'AI 起的标题',
              'type': 'todo',
              'due_date': tomorrowStr,
            }),
          ),
        ],
        finishReason: 'tool_calls',
      ),
      const LlmChatResult(content: '已创建。', finishReason: 'stop'),
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
    await tester.enterText(find.byType(TextField), '建个待办');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 点编辑 → 改标题 → 保存 → 执行（占位转圈期间用固定时长推进动画）。
    await tester.tap(find.byTooltip('编辑这条草稿'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('编辑这条日程'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, '标题'), '我改过的标题');
    await tester.tap(find.text('保存'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    // 卡片描述随编辑更新。
    expect(find.textContaining('「我改过的标题」'), findsOneWidget);
    await tester.tap(find.text('执行选中项（1）'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    // 落库的是编辑后的标题。
    expect(taskRepo.taskCount, 1);
    final Task created = (await taskRepo.getTasks()).single;
    expect(created.title, '我改过的标题');
  });

  testWidgets('AI：S9 create_course——课程落入当前学期，草稿编辑生效',
      (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTimetableRepository timetableRepo = FakeTimetableRepository();
    timetableRepo.seedSemester(Semester(
      id: 1,
      name: '2026 秋',
      startDate: DateTime(2026, 8, 31),
      totalWeeks: 16,
    ));

    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'cc1',
            name: 'create_course',
            argumentsJson: jsonEncode(<String, dynamic>{
              'name': '高等数学',
              'weekday': 1,
              'start_period': 1,
              'end_period': 2,
              'location': '教一101',
            }),
          ),
        ],
        finishReason: 'tool_calls',
      ),
      const LlmChatResult(content: '已导入。', finishReason: 'stop'),
    ];

    await tester.pumpWidget(
      harness(
        chat: chat,
        timetableRepo: timetableRepo,
        settings: FakeSettingsRepository(<String, String>{
          'ai.onboarded': '1',
          'ai.write_enabled': 'true',
        }),
        turns: turns,
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '把这张课表加进去');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 确认卡片：课程摘要（缺省周次描述为整学期）。
    expect(find.textContaining('新建课程「高等数学」'), findsOneWidget);
    expect(find.textContaining('周一 1-2节'), findsOneWidget);

    // 编辑草稿：教室改为教二303。
    await tester.tap(find.byTooltip('编辑这条草稿'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
        find.widgetWithText(TextFormField, '教室（可留空）'), '教二303');
    await tester.tap(find.text('保存'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    // 卡片描述已更新（对话框退场动画期间输入框文本可能仍在树中，放宽为存在即可）。
    expect(find.textContaining('教二303'), findsWidgets);

    await tester.tap(find.text('执行选中项（1）'));
    for (int i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 落库：归属当前学期，周次缺省为学期总周数，教室为编辑后的值。
    expect(timetableRepo.courseCount, 1);
    final Course created = (await timetableRepo.getAllCourses()).single;
    expect(created.semesterId, 1);
    expect(created.name, '高等数学');
    expect(created.weekday, 1);
    expect(created.endWeek, 16);
    expect(created.location, '教二303');
  });
}

bool _sameDayOf(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
