import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/models/chat_message.dart';
import 'package:plai/data/models/chat_queue_entry.dart';
import 'package:plai/data/repositories/chat_queue_repository.dart';
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
import 'package:plai/features/ai/ai_attach_panel.dart';
import 'package:plai/features/ai/ai_page.dart';
import 'package:plai/features/ai/ai_message_bubble.dart';
import 'package:plai/features/ai/ai_providers.dart';
import 'package:plai/features/ai/ai_queue_providers.dart';
import 'package:plai/features/ai/ai_queue_attachments.dart';
import 'package:plai/features/schedule/schedule_providers.dart';
import 'package:plai/features/timetable/course_block.dart';
import 'package:plai/features/timetable/timetable_page.dart';
import 'package:plai/features/timetable/timetable_providers.dart';
import 'package:plai/services/ai/llm_client.dart';
import 'package:plai/services/ai/models/ai_message.dart';
import 'package:plai/services/ai/models/ai_tool.dart';
import 'package:plai/services/audio/complete_sound.dart';
import 'package:plai/services/notifications/class_reminder_planner.dart';
import 'package:plai/services/notifications/notification_providers.dart';
import 'package:plai/services/notifications/notification_scheduler.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 内存版 IChatRepository。
class FakeChatRepository implements IChatRepository {
  FakeChatRepository({this.onAppend});

  final void Function(ChatMessage message)? onAppend;
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
    final ChatMessage m =
        _makeMessage(message.sessionId, message.role, message.content).copyWith(
          hasContext: message.hasContext,
          attachments: message.attachments,
          toolRecords: message.toolRecords,
        );
    (_messages[message.sessionId] ??= <ChatMessage>[]).add(m);
    onAppend?.call(m);
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
class FakeChatQueueRepository implements IChatQueueRepository {
  FakeChatQueueRepository(this.chat);
  final FakeChatRepository chat;
  final entries = <ChatQueueEntry>[];
  int next = 1;
  @override
  Future<List<ChatQueueEntry>> list({int? sessionId}) async => entries
      .where((e) => sessionId == null || e.sessionId == sessionId)
      .toList();
  @override
  Future<ChatQueueEntry> enqueue({
    required int sessionId,
    required String text,
    List<String> imagePaths = const [],
    bool includeAppState = false,
  }) async {
    final message = await chat.appendMessage(
      ChatMessage(
        sessionId: sessionId,
        role: ChatRole.user,
        content: text,
        attachments: imagePaths,
      ),
    );
    final entry = ChatQueueEntry(
      id: next++,
      sessionId: sessionId,
      userMessageId: message,
      text: text,
      imagePaths: imagePaths,
      includeAppState: includeAppState,
      createdAt: DateTime.now(),
    );
    entries.add(entry);
    return entry;
  }

  @override
  Future<int> update(
    int id, {
    ChatQueueStatus? status,
    String? error,
    Map<String, dynamic>? checkpoint,
    bool clearError = false,
  }) async {
    final i = entries.indexWhere((e) => e.id == id);
    if (i < 0) return 0;
    final e = entries[i];
    entries[i] = ChatQueueEntry(
      id: e.id,
      sessionId: e.sessionId,
      userMessageId: e.userMessageId,
      text: e.text,
      imagePaths: e.imagePaths,
      includeAppState: e.includeAppState,
      status: status ?? e.status,
      error: clearError ? null : error ?? e.error,
      checkpoint: checkpoint ?? e.checkpoint,
      createdAt: e.createdAt,
    );
    return 1;
  }

  @override
  Future<ChatQueueEntry?> cancel(int id) => withdraw(id);
  @override
  Future<ChatQueueEntry?> withdraw(int id) async {
    final i = entries.indexWhere(
      (e) => e.id == id && e.status == ChatQueueStatus.queued,
    );
    if (i < 0) return null;
    final e = entries.removeAt(i);
    chat._messages[e.sessionId]?.removeWhere((m) => m.id == e.userMessageId);
    return e;
  }

  @override
  Future<int> recoverInterrupted() async {
    final list = entries
        .where(
          (e) =>
              e.status == ChatQueueStatus.running ||
              e.status == ChatQueueStatus.waitingConfirmation,
        )
        .toList();
    for (final e in list) {
      await update(e.id, status: ChatQueueStatus.interrupted);
    }
    return list.length;
  }

  @override
  Future<List<String>> deleteSessions(List<int> ids) async {
    final paths = <String>[];
    for (final id in ids) {
      for (final m in chat.messagesOf(id)) {
        paths.addAll(m.attachments);
      }
      await chat.deleteSession(id);
    }
    entries.removeWhere((e) => ids.contains(e.sessionId));
    return paths;
  }

  @override
  Future<Map<int, String>> sessionPreviews() async => {
    for (final s in await chat.listSessions())
      s.id!:
          chat
              .messagesOf(s.id!)
              .where((m) => m.role != ChatRole.tool && m.content.isNotEmpty)
              .map((m) => m.content)
              .lastOrNull ??
          '',
  };
}

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
  }) async => _tasks.values
      .where(
        (Task t) =>
            (type == null || t.type == type) &&
            (completed == null || t.completed == completed),
      )
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
      _dailyLogs[taskId]?.contains(DateTime(date.year, date.month, date.day)) ??
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

  /// 取消提醒的调用记录（删除类用例断言「提醒被一并取消」）。
  final List<String> cancelled = <String>[];

  @override
  Future<void> scheduleTaskReminder(Task task) async {}

  @override
  Future<void> rescheduleAll({List<ClassReminderPlan>? classPlans}) async {}

  @override
  Future<void> cancelAllRemindersFor({int? courseId, int? taskId}) async {
    if (courseId != null) cancelled.add('course:$courseId');
    if (taskId != null) cancelled.add('task:$taskId');
  }
}

/// 内存版 ITimetableRepository（save_course 验证用，未触路径抛未实现）。
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

  /// 预置学期（save_course 的 create 判定用）。
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
  Future<List<Course>> getCourses(int semesterId) async =>
      _courses.values.where((Course c) => c.semesterId == semesterId).toList();

  @override
  Future<List<Course>> getCoursesByWeekday(int semesterId, int weekday) async =>
      _courses.values
          .where(
            (Course c) => c.semesterId == semesterId && c.weekday == weekday,
          )
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
  Future<List<Semester>> getSemesters() async => List<Semester>.of(_semesters);

  @override
  Future<List<Period>> getPeriods() async => const <Period>[];

  @override
  Future<List<Holiday>> getHolidays({
    int? courseId,
    DateTime? from,
    DateTime? to,
  }) async => const <Holiday>[];

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
    int maxRetries = LlmClient.defaultMaxRetries,
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

/// 真实 HTTP/SSE 解析在实际异步区运行，页面仍由 widget 假时钟驱动。
class _GatedLlmClient extends LlmClient {
  _GatedLlmClient({this.first})
    : super(baseUrl: 'https://example.com', model: 'test');
  final LlmChatResult? first;
  final gate = Completer<void>();
  final requests = <List<AiMessage>>[];
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
    requests.add(List.of(messages));
    if (requests.length == 1) {
      await gate.future;
      if (first != null) return first!;
    }
    final text = '已回复第 ${requests.length} 条消息。';
    onDelta?.call(LlmDelta(contentDelta: text));
    return LlmChatResult(content: text, finishReason: 'stop', model: 'test');
  }

  @override
  void close() {} // 一个脚本覆盖测试中多个独立请求。
}

class _WidgetLlmClient extends LlmClient {
  _WidgetLlmClient(this.tester, http.Client transport)
    : super(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'test-key',
        model: 'test-model',
        httpClient: transport,
      );

  final WidgetTester tester;
  final Completer<LlmChatResult> firstResponse = Completer<LlmChatResult>();

  @override
  Future<LlmChatResult> chatStream({
    required List<AiMessage> messages,
    List<Map<String, dynamic>>? tools,
    Object? toolChoice,
    bool jsonMode = false,
    double? temperature,
    Duration? timeout,
    int maxRetries = LlmClient.defaultMaxRetries,
    void Function(LlmDelta delta)? onDelta,
  }) async {
    final result = (await tester.runAsync(
      () => super.chatStream(
        messages: messages,
        tools: tools,
        toolChoice: toolChoice,
        jsonMode: jsonMode,
        temperature: temperature,
        timeout: timeout,
        maxRetries: maxRetries,
        onDelta: onDelta,
      ),
    ))!;
    if (!firstResponse.isCompleted) firstResponse.complete(result);
    return result;
  }
}

/// 1x1 透明 PNG（网格缩略图用）。
final Uint8List kThumbBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlE'
  'QVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

/// 假相册数据源：首页 2 张照片。
class FakeGallerySource implements AiGallerySource {
  FakeGallerySource({required this.paths});

  /// 每张照片的原图路径（须真实存在，供 data URI 读取）。
  final List<String> paths;

  @override
  Future<void> ensurePermission() async {}

  @override
  Future<List<AiGalleryPhoto>> fetchPage(int page, int size) async {
    if (page > 0) return const <AiGalleryPhoto>[];
    return <AiGalleryPhoto>[
      for (int i = 0; i < paths.length; i++)
        AiGalleryPhoto(
          id: 'photo_$i',
          loadThumb: () async => kThumbBytes,
          loadOriginPath: () async => paths[i],
        ),
    ];
  }
}

/// 假完成提示音：记录点播路径，不触真音频。
class _SoundRecorder implements CompletionSound {
  final List<String> paths = <String>[];

  @override
  Future<void> play(String path) async {
    paths.add(path);
  }
}

/// widget 假时钟下使用同步文件适配；生产异步附件服务另有真实文件回归。
class _WidgetAttachments extends AiQueueAttachments {
  final paths = <String>[];
  @override
  Future<List<String>> retain(List<String> sources) async {
    final result = <String>[];
    for (final source in sources) {
      final target =
          '${Directory.systemTemp.path}/plai-queue-${DateTime.now().microsecondsSinceEpoch}-${paths.length}.jpg';
      File(source).copySync(target);
      paths.add(target);
      result.add(target);
    }
    return result;
  }

  @override
  Future<List<String>> dataUris(List<String> sources) async => [
    for (final path in sources)
      AiQueueAttachments.encodeImage(path, File(path).readAsBytesSync()),
  ];
  @override
  Future<void> remove(List<String> sources) async {
    for (final path in sources) {
      if (paths.contains(path) && File(path).existsSync()) {
        File(path).deleteSync();
      }
    }
  }
}

Future<void> openInitialAiChat(WidgetTester tester) async {
  if (find.byKey(const Key('ai_new_conversation')).evaluate().isEmpty) return;
  final sessions = find.byWidgetPredicate(
    (w) =>
        w is ListTile &&
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('ai_session_'),
  );
  await tester.tap(
    sessions.evaluate().isEmpty
        ? find.byKey(const Key('ai_new_conversation'))
        : sessions.first,
  );
  await tester.pumpAndSettle();
}

void main() {
  Widget harness({
    required FakeChatRepository chat,
    ISettingsRepository? settings,
    ITaskRepository? taskRepo,
    ITimetableRepository? timetableRepo,

    /// 根部件（缺省 [AiPage]）；端到端用例可换成含真实课表页的外壳。
    Widget? home,
    AiGallerySource? gallery,
    List<TodayCourse> courses = const <TodayCourse>[],
    List<Task> tasks = const <Task>[],
    List<TodayCourse> Function(DateTime day)? dayCourses,
    void Function(List<AiMessage>)? onWire,
    void Function(List<Map<String, dynamic>>? tools)? onRequest,
    List<LlmChatResult> turns = const <LlmChatResult>[],
    String reply = '已收到。',
    CompletionSound? sound,
    FakeScheduler? scheduler,
    LlmClient? client,
    double? textScale,
  }) {
    final ISettingsRepository settingsRepo =
        settings ?? FakeSettingsRepository();
    return ProviderScope(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        chatQueueRepositoryProvider.overrideWithValue(
          FakeChatQueueRepository(chat),
        ),
        aiQueueAttachmentsProvider.overrideWithValue(_WidgetAttachments()),
        settingsRepositoryProvider.overrideWithValue(settingsRepo),
        taskRepositoryProvider.overrideWithValue(
          taskRepo ?? FakeTaskRepository(),
        ),
        timetableRepositoryProvider.overrideWithValue(
          timetableRepo ?? FakeTimetableRepository(),
        ),
        if (gallery != null) aiGallerySourceProvider.overrideWithValue(gallery),
        notificationSchedulerProvider.overrideWithValue(
          scheduler ?? FakeScheduler(),
        ),
        if (sound != null)
          completionSoundPlayerProvider.overrideWithValue(sound),
        llmConfigProvider.overrideWith(
          (ref) async => const LlmConfig(
            enabled: true,
            baseUrl: 'https://api.example.com/v1',
            apiKey: 'k',
            model: 'm',
          ),
        ),
        llmClientFactoryProvider.overrideWith(
          (ref) =>
              ({
                required String baseUrl,
                String apiKey = '',
                required String model,
              }) =>
                  client ??
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
            (ref, DateTime day) async => dayCourses(day),
          ),
      ],
      child: MaterialApp(
        home: home ?? const AiPage(),
        builder: textScale == null
            ? null
            : (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
      ),
    );
  }

  for (final size in [
    const Size(320, 568),
    const Size(360, 800),
    const Size(1100, 900),
  ]) {
    for (final scale in [1.0, 2.0]) {
      for (final keyboard in [0.0, 300.0]) {
        testWidgets(
          'AI起始页布局 ${size.width}×${size.height} 字号$scale 键盘$keyboard',
          (tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
            addTearDown(tester.view.reset);
            final chat = FakeChatRepository();
            for (var i = 0; i < 8; i++) {
              chat.seedSession(
                title: '很长的课程作业安排和提醒会话标题第$i项',
                turns: [
                  (ChatRole.assistant, '这是一条包含课程、任务与提醒的很长的历史消息摘要，用来验证布局。'),
                ],
              );
            }
            await tester.pumpWidget(harness(chat: chat, textScale: scale));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(
              find.byKey(const Key('ai_new_conversation')).hitTestable(),
              findsOneWidget,
            );
            await tester.scrollUntilVisible(
              find.text('管理'),
              80,
              scrollable: find.byType(Scrollable).first,
            );
            await Scrollable.ensureVisible(
              tester.element(find.text('管理')),
              alignment: 0,
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('管理'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.text('删除所选（0）').hitTestable(), findsOneWidget);
            expect(find.byKey(const Key('ai_new_conversation')), findsNothing);
          },
        );
      }
    }
  }

  testWidgets('AI：新建悬浮按钮固定右下角，列表末项不被遮挡，点击进入新对话', (tester) async {
    final chat = FakeChatRepository();
    for (var i = 0; i < 20; i++) {
      chat.seedSession(title: '会话$i');
    }
    final last = (await chat.listSessions()).last;
    await tester.pumpWidget(harness(chat: chat));
    await tester.pumpAndSettle();
    final button = find.byKey(const Key('ai_new_conversation'));
    expect(find.byType(FloatingActionButton), findsOneWidget);
    final before = tester.getRect(button);
    expect(before.right, closeTo(784, 1));
    expect(before.bottom, closeTo(584, 1));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -5000));
    await tester.pumpAndSettle();
    expect(tester.getRect(button), before);
    expect(
      tester.getBottomLeft(find.byKey(ValueKey('ai_session_${last.id}'))).dy,
      lessThan(before.top),
    );
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('开始一段对话吧'), findsOneWidget);
    expect(chat.sessionCount, 20);
  });

  for (final keyboard in [300.0, 380.0]) {
    testWidgets('AI：小屏大字键盘$keyboard 下处理中仍可编写多行下一条消息', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final client = _GatedLlmClient();
      await tester.pumpWidget(
        harness(
          chat: FakeChatRepository(),
          client: client,
          textScale: 2,
          settings: FakeSettingsRepository({'ai.onboarded': '1'}),
        ),
      );
      await tester.pumpAndSettle();
      await openInitialAiChat(tester);
      await tester.enterText(find.byType(TextField), '第一条消息');
      await tester.pump();
      await tester.tap(find.byTooltip('发送'));
      await tester.pump();
      await tester.pump();
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      await tester.pump();
      await tester.enterText(
        find.byType(TextField),
        '第一行\n第二行\n第三行\n第四行\n第五行\n第六行',
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('发送').hitTestable(), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
      client.gate.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('AI：重命名退场安全，后续发送不覆盖用户标题', (tester) async {
    final chat = FakeChatRepository();
    final session = chat.seedSession(title: '旧名称');
    await tester.pumpWidget(
      harness(
        chat: chat,
        settings: FakeSettingsRepository({'ai.onboarded': '1'}),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('会话操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '我自己的会话标题');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(ValueKey('ai_session_${session.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '后续消息');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect((await chat.getSessionById(session.id!))!.title, '我自己的会话标题');
  });

  testWidgets('AI：起始页搜索与批量删除只作用于当前结果，搜索变化清空勾选', (tester) async {
    final chat = FakeChatRepository();
    chat.seedSession(
      title: '力学作业',
      turns: const [(ChatRole.assistant, '力学摘要')],
    );
    chat.seedSession(title: '物理作业');
    final keep = chat.seedSession(title: '闲聊', pinned: true);
    await tester.pumpWidget(harness(chat: chat));
    await tester.pumpAndSettle();
    expect(find.text('最近会话'), findsOneWidget);
    expect(chat.sessionCount, 3);
    final titleRect = tester.getRect(
      find.byKey(const ValueKey('ai_session_title_1')),
    );
    final timeRect = tester.getRect(
      find.byKey(const ValueKey('ai_session_time_1')),
    );
    final preview = find.byKey(const ValueKey('ai_session_preview_1'));
    expect(timeRect.left, greaterThan(titleRect.right));
    expect(timeRect.center.dy, closeTo(titleRect.center.dy, 1));
    expect(tester.widget<Text>(preview).maxLines, 1);
    expect(tester.getTopLeft(preview).dy, greaterThan(titleRect.top));
    expect(
      tester.getSize(find.byKey(const ValueKey('ai_session_1'))).height,
      lessThan(80),
    );
    expect(find.text('继续上次的想法'), findsNothing);
    expect(find.text('选择一段历史对话，或从新的话题开始。'), findsNothing);
    expect(find.byKey(const Key('ai_session_search')), findsNothing);
    expect(tester.getTopLeft(find.byTooltip('搜索会话')).dx, lessThan(80));
    await tester.tap(find.byTooltip('搜索会话'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byKey(const Key('ai_session_search')),
      ),
      findsOneWidget,
    );
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.enterText(find.byKey(const Key('ai_session_search')), '作业');
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('闲聊'), findsNothing);
    expect(find.text('力学摘要'), findsOneWidget);
    await tester.tap(find.text('管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('ai_session_search')), '力学');
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('已选 0 项'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('ai_session_search')), '作业');
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除所选（2）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect((await chat.listSessions()).map((s) => s.id), [keep.id]);
    await tester.tap(find.byTooltip('关闭搜索'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai_session_search')), findsNothing);
    expect(find.byKey(ValueKey('ai_session_${keep.id}')), findsOneWidget);
    await tester.tap(find.byTooltip('搜索会话'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      isEmpty,
    );
  });

  testWidgets('AI：聊天页删除需确认，完成后返回列表且保留其他会话', (tester) async {
    final chat = FakeChatRepository();
    final first = chat.seedSession(title: '删除测试');
    final keep = chat.seedSession(title: '保留测试');
    await tester.pumpWidget(harness(chat: chat));
    await tester.pumpAndSettle();
    expect(find.byTooltip('设置'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('ai_session_${first.id}')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('设置'), findsNothing);
    await tester.tap(find.byTooltip('删除当前会话'));
    await tester.pumpAndSettle();
    expect(find.text('删除当前会话？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(chat.sessionCount, 2);
    await tester.tap(find.byTooltip('删除当前会话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect((await chat.listSessions()).map((s) => s.id), [keep.id]);
    expect(find.text('最近会话'), findsOneWidget);
    expect(find.byTooltip('设置'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ai_new_conversation')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == '删除当前会话',
            ),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('AI：处理中聊天页的删除入口禁用', (tester) async {
    final chat = FakeChatRepository();
    final client = _GatedLlmClient();
    await tester.pumpWidget(
      harness(
        chat: chat,
        client: client,
        settings: FakeSettingsRepository({'ai.onboarded': '1'}),
      ),
    );
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.enterText(find.byType(TextField), '处理中');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == '删除当前会话',
            ),
          )
          .onPressed,
      isNull,
    );
    client.gate.complete();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == '删除当前会话',
            ),
          )
          .onPressed,
      isNotNull,
    );
  });

  for (final variant in [
    (const Size(800, 600), 1.0, 300.0),
    (const Size(320, 568), 2.0, 300.0),
    (const Size(320, 568), 2.0, 380.0),
  ]) {
    testWidgets('AI：撤回编辑自动弹出键盘，输入栏在键盘开合后始终贴底 $variant', (tester) async {
      tester.view.physicalSize = variant.$1;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final client = _GatedLlmClient();
      await tester.pumpWidget(
        harness(
          chat: FakeChatRepository(),
          client: client,
          textScale: variant.$2,
          settings: FakeSettingsRepository({'ai.onboarded': '1'}),
        ),
      );
      await tester.pumpAndSettle();
      await openInitialAiChat(tester);
      await tester.enterText(find.byType(TextField), '当前处理');
      await tester.pump();
      await tester.tap(find.byTooltip('发送'));
      await tester.pump();
      await tester.pump();
      await tester.enterText(find.byType(TextField), '撤回后修改的消息');
      await tester.pump();
      await tester.tap(find.byTooltip('发送'));
      await tester.pump();
      await tester.pump();
      await tester.enterText(find.byType(TextField), '原有草稿');
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      tester.testTextInput.hide();
      await tester.pump();
      await tester.tap(find.byTooltip('撤回修改'));
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '撤回后修改的消息',
      );
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
      expect(tester.testTextInput.isVisible, isTrue);
      final height =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      for (final inset in [0.0, variant.$3, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull);
        expect(
          tester.getBottomLeft(find.byKey(const Key('ai_message_composer'))).dy,
          closeTo(height - inset, 1),
          reason: '输入栏下方不能留下未使用的弹性布局空间',
        );
      }
      tester.view.resetViewInsets();
      await tester.tap(find.text('取消编辑'));
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '原有草稿',
      );
      client.gate.complete();
      await tester.pumpAndSettle();
    });
  }

  testWidgets('AI：跨会话排队与撤回编辑保护已有草稿，按发送顺序执行', (tester) async {
    final chat = FakeChatRepository();
    final a = chat.seedSession(title: 'A会话');
    final b = chat.seedSession(title: 'B会话');
    final client = _GatedLlmClient();
    await tester.pumpWidget(
      harness(
        chat: chat,
        client: client,
        settings: FakeSettingsRepository({'ai.onboarded': '1'}),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('ai_session_${a.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'A正在处理');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(client.requests, hasLength(1));
    await tester.enterText(find.byType(TextField), 'A未发送草稿');
    await tester.pump();
    await tester.tap(find.byTooltip('会话列表'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('ai_session_${b.id}')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'B排队消息');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.text('排队中'), findsOneWidget);
    expect(client.requests, hasLength(1));
    final queuedBubble = find.byWidgetPredicate(
      (w) => w is AiMessageBubble && w.content == 'B排队消息',
    );
    final surface = find.descendant(
      of: queuedBubble,
      matching: find.byKey(const Key('ai_message_surface')),
    );
    final pill = find.descendant(
      of: queuedBubble,
      matching: find.byWidgetPredicate(
        (w) =>
            w is Material &&
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('ai_queue_pill_'),
      ),
    );
    expect(pill, findsOneWidget);
    expect(
      tester.getRect(pill).right,
      closeTo(tester.getRect(surface).right, 1),
    );
    expect(tester.getRect(pill).top, lessThan(tester.getRect(surface).bottom));
    expect(find.text('撤回修改'), findsNothing);
    expect(find.text('取消发送'), findsNothing);
    expect(find.byTooltip('撤回修改').hitTestable(), findsOneWidget);
    await tester.enterText(find.byType(TextField), '取消验证');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await tester.pump();
    final cancelBubble = find.byWidgetPredicate(
      (w) => w is AiMessageBubble && w.content == '取消验证',
    );
    await tester.tap(
      find.descendant(of: cancelBubble, matching: find.byTooltip('取消发送')),
    );
    await tester.pump();
    await tester.pump();
    expect(chat.messagesOf(b.id!).any((m) => m.content == '取消验证'), isFalse);
    expect(client.requests, hasLength(1));
    await tester.enterText(find.byType(TextField), 'B原有草稿');
    await tester.pump();
    await tester.tap(find.byTooltip('撤回修改'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'B排队消息',
    );
    await tester.enterText(find.byType(TextField), 'B修改后排队');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'B原有草稿',
    );
    client.gate.complete();
    await tester.pumpAndSettle();
    expect(client.requests, hasLength(2));
    expect(client.requests.last.last.text, 'B修改后排队');
    expect(
      client.requests.last
          .where((m) => m.role == AiRole.user)
          .map((m) => m.text),
      ['B修改后排队'],
    );
    expect((await chat.getSessionById(b.id!))!.title, 'B会话');
    await tester.tap(find.byTooltip('会话列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('ai_session_${a.id}')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'A未发送草稿',
    );
  });

  testWidgets('AI：其他会话待确认只提示来源，稍后确认保留队列，跳过后自动继续', (tester) async {
    final chat = FakeChatRepository();
    final a = chat.seedSession(title: 'A会话');
    final b = chat.seedSession(title: 'B会话');
    final client = _GatedLlmClient(
      first: LlmChatResult(
        toolCalls: [
          AiToolCall(
            id: 'draft',
            name: 'save_task',
            argumentsJson: jsonEncode({
              'action': 'create',
              'title': '不要创建',
              'due_date': '2026-12-01',
            }),
          ),
        ],
        finishReason: 'tool_calls',
        model: 'test',
      ),
    );
    final tasks = FakeTaskRepository();
    await tester.pumpWidget(
      harness(
        chat: chat,
        client: client,
        taskRepo: tasks,
        settings: FakeSettingsRepository({
          'ai.onboarded': '1',
          'ai.write_enabled': 'true',
        }),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('ai_session_${a.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '创建一条任务');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    await tester.tap(find.byTooltip('会话列表'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('ai_session_${b.id}')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'B等待发送');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    client.gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('AI 请求修改数据'), findsNothing);
    expect(find.textContaining('A会话」等待确认'), findsOneWidget);
    expect(client.requests, hasLength(1));
    await tester.tap(find.text('查看确认').first);
    await tester.pumpAndSettle();
    expect(find.text('AI 请求修改数据'), findsOneWidget);
    await tester.tap(find.text('稍后确认'));
    await tester.pumpAndSettle();
    expect(find.text('AI 请求修改数据'), findsNothing);
    expect(client.requests, hasLength(1));
    await tester.tap(find.text('查看确认').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部跳过'));
    await tester.pumpAndSettle();
    expect(tasks.taskCount, 0);
    expect(client.requests, hasLength(2));
    expect(client.requests.last.last.text, 'B等待发送');
  });

  for (final bool sse in <bool>[true, false]) {
    testWidgets('AI：真实客户端${sse ? "分段 SSE" : "非 SSE 回退"}完整显示并落库', (
      WidgetTester tester,
    ) async {
      final Completer<void> answered = Completer<void>();
      final FakeChatRepository chat = FakeChatRepository(
        onAppend: (message) {
          if (message.role == ChatRole.assistant && !answered.isCompleted) {
            answered.complete();
          }
        },
      );
      const String answer = '你好，已经收到你的完整消息。';
      final LlmClient client = _WidgetLlmClient(
        tester,
        MockClient.streaming((
          http.BaseRequest request,
          Stream<List<int>> bodyStream,
        ) async {
          final String requestBody = await http.ByteStream(bodyStream)
              .bytesToString();
          expect(jsonDecode(requestBody)['stream'], isTrue);
          final String body = sse
              ? <String>[
                  for (final String part in <String>['你', '好，', '已经收到你的完整消息。'])
                    'data: ${jsonEncode({
                      "choices": [
                        {
                          "index": 0,
                          "delta": {"content": part},
                        },
                      ],
                    })}\n\n',
                  'data: [DONE]\n\n',
                ].join()
              : jsonEncode({
                  'choices': [
                    {
                      'message': {'content': answer},
                      'finish_reason': 'stop',
                    },
                  ],
                });
          return http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode(body)),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        harness(
          chat: chat,
          settings: FakeSettingsRepository({'ai.onboarded': '1'}),
          timetableRepo: FakeTimetableRepository(),
          client: client,
        ),
      );
      await tester.pumpAndSettle();
      await openInitialAiChat(tester);
      await tester.pumpAndSettle();
      await openInitialAiChat(tester);
      await tester.enterText(find.byType(TextField), '你好');
      await tester.pump();
      await tester.tap(find.byTooltip('发送'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await answered.future;
      await tester.pumpAndSettle();

      final int sid = (await chat.listSessions()).single.id!;
      expect(chat.messagesOf(sid).last.content, answer);
      expect(find.text(answer), findsOneWidget);
      expect(find.textContaining('这个回答不完整'), findsNothing);
    });
  }

  testWidgets('AI：真实 SSE 分片工具参数 → 两条跨期草稿 → 确认后保存及每日提醒', (
    WidgetTester tester,
  ) async {
    final chat = FakeChatRepository();
    final taskRepo = FakeTaskRepository();
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final end = start.add(const Duration(days: 3));
    String date(DateTime d) => d.toIso8601String().substring(0, 10);
    final titles = ['理论力学作业', '高等物理作业'];
    final arguments = [
      for (final title in titles)
        jsonEncode({
          'action': 'create',
          'title': title,
          'type': 'span',
          'start_date': date(start),
          'due_date': date(end),
          'remind_time': '08:00',
        }),
    ];
    String frame(Map<String, dynamic> delta) =>
        'data: ${jsonEncode({
          'choices': [
            {'index': 0, 'delta': delta},
          ],
        })}\n\n';
    final body = <String>[
      frame({'content': '我来提交草稿'}),
      frame({
        'tool_calls': [
          for (int i = 0; i < 2; i++)
            {
              'index': i,
              'id': 'call_$i',
              'type': 'function',
              'function': {
                'name': 'save_task',
                'arguments': arguments[i].substring(0, 21),
              },
            },
        ],
      }),
      frame({
        'tool_calls': [
          for (int i = 0; i < 2; i++)
            {
              'index': i,
              'function': {'arguments': arguments[i].substring(21)},
            },
        ],
      }),
      'data: [DONE]\n\n',
    ].join();
    int requests = 0;
    final transport = MockClient.streaming((request, stream) async {
      requests++;
      final sent = jsonDecode(await http.ByteStream(stream).bytesToString());
      expect(
        sent['tools'].any((t) => t['function']['name'] == 'save_task'),
        isTrue,
      );
      final bytes = utf8.encode(body);
      // 字节切片跨越 UTF-8 中文和 SSE 行边界，走真实解码与参数拼接。
      return http.StreamedResponse(
        Stream.fromIterable([
          for (int i = 0; i < bytes.length; i += 7)
            bytes.sublist(i, (i + 7).clamp(0, bytes.length)),
        ]),
        200,
      );
    });
    addTearDown(transport.close);
    final client = _WidgetLlmClient(tester, transport);
    await tester.pumpWidget(
      harness(
        chat: chat,
        taskRepo: taskRepo,
        timetableRepo: FakeTimetableRepository(),
        client: client,
        settings: FakeSettingsRepository({
          'ai.onboarded': '1',
          'ai.write_enabled': 'true',
        }),
      ),
    );
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.enterText(find.byType(TextField), '创建两个一次性跨期任务，每天8点提醒');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await client.firstResponse.future;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('执行选中项（2）'), findsOneWidget);
    expect(taskRepo.taskCount, 0);
    await tester.tap(find.text('执行选中项（2）'));
    await tester.pumpAndSettle();
    final tasks = await taskRepo.getTasks();
    expect(tasks.map((t) => t.title), titles);
    for (final task in tasks) {
      expect(task.type, TaskType.span);
      expect(task.startDate, start);
      expect(task.dueDate, end);
      expect(task.dailyRemindTime, '08:00');
      expect(task.reminderRepeat, ReminderRepeat.daily);
    }
    expect(requests, 1);
    final sid = (await chat.listSessions()).single.id!;
    final stored = chat.messagesOf(sid).map((m) => m.content).join('\n');
    expect(stored, isNot(contains('我来提交草稿')));
    expect(stored, contains('已完成：'));
  });

  testWidgets('AI：空态 + 知情对话框一次 + 发送自动建会话并流式入流落库', (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeSettingsRepository settings = FakeSettingsRepository();
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(chat: chat, settings: settings, reply: '已收到你的消息。'),
    );
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();

    // 空态引导。
    expect(find.text('开始一段对话吧'), findsOneWidget);
    expect(find.text('关于 AI 对话'), findsNothing);
    expect(find.widgetWithText(TextField, '输入消息'), findsOneWidget);

    // 输入并发送 → 先弹知情对话框。
    await openInitialAiChat(tester);
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
    await openInitialAiChat(tester);
    await tester.enterText(find.byType(TextField), '再说一遍');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(find.text('关于 AI 对话'), findsNothing);
  });

  testWidgets('AI：键盘弹出时消息区贴住输入框（reverse 列表零误差）', (WidgetTester tester) async {
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
    await openInitialAiChat(tester);
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
      turns: const [(ChatRole.user, '早'), (ChatRole.assistant, '早安世界')],
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
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();

    // 进入自动选中最近会话（第一个）。
    expect(find.text('hello world'), findsOneWidget);

    // 打开历史面板（推挤式），列出历史，切到「第二会话」。
    // 注意：面板开启时 AppBar 仍显示当前会话标题「你好」，
    // 故断言只针对唯一文本的「第二会话」。
    await tester.tap(find.byTooltip('会话列表'));
    await tester.pumpAndSettle();
    expect(find.text('新建对话'), findsOneWidget);
    expect(find.text('第二会话'), findsOneWidget);

    await tester.tap(find.text('第二会话'));
    await tester.pumpAndSettle();
    expect(find.text('早安世界'), findsOneWidget);
    expect(find.text('hello world'), findsNothing);
  });

  testWidgets('AI：返回会话列表后保留文字草稿，新建不增加空会话', (tester) async {
    final chat = FakeChatRepository();
    final first = chat.seedSession(title: '第一会话');
    final second = chat.seedSession(title: '第二会话');
    await tester.pumpWidget(harness(chat: chat));
    await tester.pumpAndSettle();
    expect(find.text('最近会话'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('ai_session_${first.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '第一份草稿');
    await tester.tap(find.byTooltip('会话列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('ai_session_${second.id}')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    await tester.enterText(find.byType(TextField), '第二份草稿');
    await tester.tap(find.byTooltip('会话列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('ai_session_${first.id}')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '第一份草稿',
    );
    await tester.tap(find.byTooltip('新建对话'));
    await tester.pumpAndSettle();
    expect(chat.sessionCount, 2);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('AI：返回列表收起键盘，删除会话后不抢焦点', (tester) async {
    final chat = FakeChatRepository();
    chat.seedSession(title: '待删会话');
    await tester.pumpWidget(harness(chat: chat));
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('会话列表'));
    await tester.pumpAndSettle();
    expect(find.byType(EditableText), findsNothing);
    await tester.tap(find.byTooltip('会话操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(chat.sessionCount, 0);
    expect(find.byType(EditableText), findsNothing);
  });
  testWidgets('AI：S6 工具循环——模型调只读工具本地执行回传并落库', (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final DateTime tomorrow = DateTime.now().add(const Duration(days: 1));
    final DateTime tomorrowDay = DateTime(
      tomorrow.year,
      tomorrow.month,
      tomorrow.day,
    );
    final String tomorrowStr =
        '${tomorrow.year.toString().padLeft(4, '0')}-'
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
            name: 'query',
            argumentsJson: '{"action": "day", "date": "$tomorrowStr"}',
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
        settings: FakeSettingsRepository(<String, String>{'ai.onboarded': '1'}),

        turns: turns,
        onWire: wires.add,
        onRequest: requests.add,
        dayCourses: (DateTime day) => day == tomorrowDay
            ? const <TodayCourse>[tomorrowCourse]
            : const <TodayCourse>[],
      ),
    );
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();

    await openInitialAiChat(tester);
    await tester.enterText(find.byType(TextField), '我明天有几堂课');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    // 两轮请求：第一轮带工具定义；第二轮 wire 含 assistant 工具调用与 tool 结果。
    expect(requests.length, 2);
    expect(requests[0], isNotNull);
    expect(
      wires[1].any(
        (AiMessage m) =>
            m.role == AiRole.tool &&
            m.toolCallId == 'c1' &&
            (m.text?.contains('高等数学') ?? false),
      ),
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

  testWidgets('AI：S6 轮次上限——达上限后的请求不再提供工具', (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final List<LlmChatResult> turns = <LlmChatResult>[
      for (int i = 0; i < maxToolRounds; i++)
        LlmChatResult(
          toolCalls: <AiToolCall>[
            AiToolCall(id: 'c$i', name: 'query', argumentsJson: '{}'),
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
        settings: FakeSettingsRepository(<String, String>{'ai.onboarded': '1'}),

        turns: turns,
        onRequest: requests.add,
      ),
    );
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();

    await openInitialAiChat(tester);
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

  testWidgets('AI：S7 门控——写开关关闭时请求不含写工具', (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final List<List<Map<String, dynamic>>?> requests =
        <List<Map<String, dynamic>>?>[];

    await tester.pumpWidget(
      harness(
        chat: chat,
        settings: FakeSettingsRepository(<String, String>{'ai.onboarded': '1'}),
        onRequest: requests.add,
      ),
    );
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    expect(requests, hasLength(1));
    final List<Map<String, dynamic>> tools = requests[0]!;
    // 写工具整体受门控：开关关闭时模型拿不到任何写工具。
    expect(
      tools.any(
        (Map<String, dynamic> t) => t['function']['name'] == 'save_task',
      ),
      isFalse,
    );
    expect(
      tools.any(
        (Map<String, dynamic> t) => t['function']['name'] == 'save_course',
      ),
      isFalse,
    );
    expect(
      tools.any((Map<String, dynamic> t) => t['function']['name'] == 'query'),
      isTrue,
    );
  });

  testWidgets('AI：S7 门控——写开关开启时请求包含写工具', (WidgetTester tester) async {
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
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    expect(requests, hasLength(1));
    final List<Map<String, dynamic>> tools = requests[0]!;
    // 写工具合并成 save_task / save_course 两条，四条能力都在里面。
    expect(
      tools.any(
        (Map<String, dynamic> t) => t['function']['name'] == 'save_task',
      ),
      isTrue,
    );
    expect(
      tools.any(
        (Map<String, dynamic> t) => t['function']['name'] == 'save_course',
      ),
      isTrue,
    );
    final Map<String, dynamic> saveTask = tools.firstWhere(
      (Map<String, dynamic> t) => t['function']['name'] == 'save_task',
    );
    final Map<String, dynamic> params =
        (saveTask['function'] as Map<String, dynamic>)['parameters']
            as Map<String, dynamic>;
    final List<dynamic> actions =
        ((params['properties'] as Map<String, dynamic>)['action']
                as Map<String, dynamic>)['enum']
            as List<dynamic>;
    expect(
      actions,
      containsAll(<String>['create', 'update', 'complete', 'delete']),
    );
  });

  testWidgets('AI：S7 写工具——确认后执行 save_task(create) 并回传结果', (
    WidgetTester tester,
  ) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final DateTime tomorrow = DateTime.now().add(const Duration(days: 1));
    final String tomorrowStr =
        '${tomorrow.year.toString().padLeft(4, '0')}-'
        '${tomorrow.month.toString().padLeft(2, '0')}-'
        '${tomorrow.day.toString().padLeft(2, '0')}';
    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'w1',
            name: 'save_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'create',
              'title': '交高数作业',
              'type': 'todo',
              'due_date': tomorrowStr,
              'remind_time': '07:50',
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
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
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
    expect(created.dailyRemindTime, '07:50'); // 提醒要求进字段而非描述
    expect(created.description, isNot(contains('提醒')));

    // tool 消息回传 created；面板关闭；结果行直接说明做成了什么。
    // （只写不查时不再等模型复述一轮，2026-11-02 起改由确认卡文案收尾。）
    final int sessionId = (await chat.listSessions()).single.id!;
    final ChatMessage toolMsg = chat
        .messagesOf(sessionId)
        .firstWhere((ChatMessage m) => m.role == ChatRole.tool);
    expect(toolMsg.content, contains('"created"'));
    expect(find.text('AI 请求修改数据'), findsNothing);
    expect(find.textContaining('已完成：新建待办任务「交高数作业」'), findsOneWidget);
    expect(find.text('已为你新建日程。'), findsNothing);
  });

  testWidgets('AI：S7 写工具——全部跳过后不执行且回传 skipped', (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final DateTime tomorrow = DateTime.now().add(const Duration(days: 1));
    final String tomorrowStr =
        '${tomorrow.year.toString().padLeft(4, '0')}-'
        '${tomorrow.month.toString().padLeft(2, '0')}-'
        '${tomorrow.day.toString().padLeft(2, '0')}';
    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'w1',
            name: 'save_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'create',
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
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
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
    final ChatMessage toolMsg = chat
        .messagesOf(sessionId)
        .firstWhere((ChatMessage m) => m.role == ChatRole.tool);
    expect(toolMsg.content, contains('"skipped"'));
    expect(find.textContaining('已跳过：新建待办任务「不要建这条」'), findsOneWidget);
    expect(find.text('好的，没有创建。'), findsNothing);
  });

  testWidgets('AI：只写不查——确认后不再向模型要复述轮，只发一次请求', (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final DateTime tomorrow = DateTime.now().add(const Duration(days: 1));
    final String tomorrowStr =
        '${tomorrow.year.toString().padLeft(4, '0')}-'
        '${tomorrow.month.toString().padLeft(2, '0')}-'
        '${tomorrow.day.toString().padLeft(2, '0')}';
    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'w1',
            name: 'save_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'create',
              'title': '交高数作业',
              'type': 'todo',
              'due_date': tomorrowStr,
            }),
          ),
        ],
        finishReason: 'tool_calls',
      ),
      // 这一轮不该被请求；真请求了就会显示「已创建。」（旧行为的证据）。
      const LlmChatResult(content: '已创建。', finishReason: 'stop'),
    ];
    final List<List<Map<String, dynamic>>?> requests =
        <List<Map<String, dynamic>>?>[];

    await tester.pumpWidget(
      harness(
        chat: chat,
        taskRepo: taskRepo,
        settings: FakeSettingsRepository(<String, String>{
          'ai.onboarded': '1',
          'ai.write_enabled': 'true',
        }),
        turns: turns,
        onRequest: requests.add,
      ),
    );
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.enterText(find.byType(TextField), '帮我建个明天交高数作业的待办');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('执行选中项（1）'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // 只写不查：确认执行后不再向模型要复述（B），整轮只发 1 次请求。
    expect(requests.length, 1);
    expect(find.text('已创建。'), findsNothing);
    expect(find.textContaining('已完成：新建待办任务「交高数作业」'), findsOneWidget);
  });

  testWidgets('AI：写操作结果行不会被「回答太短」兜底顶掉（2026-11-02 回归）', (
    WidgetTester tester,
  ) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final DateTime tomorrow = DateTime.now().add(const Duration(days: 1));
    final String tomorrowStr =
        '${tomorrow.year.toString().padLeft(4, '0')}-'
        '${tomorrow.month.toString().padLeft(2, '0')}-'
        '${tomorrow.day.toString().padLeft(2, '0')}';
    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'w1',
            name: 'save_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'create',
              'title': '交物理作业',
              'type': 'todo',
              'due_date': tomorrowStr,
            }),
          ),
        ],
        finishReason: 'tool_calls',
      ),
      // 只写不查 → 不再请求这一轮；即便模型真给了短句也不能顶掉结果行。
      const LlmChatResult(content: '好', finishReason: 'stop'),
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
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.enterText(find.byType(TextField), '帮我建个交物理作业的待办');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('执行选中项（1）'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // 真机现象：写完之后出现的却是「这个回答不完整…」，结果行被顶掉。
    expect(find.textContaining('已完成：新建待办任务「交物理作业」'), findsOneWidget);
    expect(find.textContaining('这个回答不完整'), findsNothing);
    final int sessionId = (await chat.listSessions()).single.id!;
    final List<String> contents = chat
        .messagesOf(sessionId)
        .map((ChatMessage m) => m.content)
        .toList();
    expect(contents.where((String c) => c.contains('这个回答不完整')), isEmpty);
  });

  testWidgets('AI：查完却只回几个字时，不摆原始 JSON、只提示换个问法（2026-11-02 回归）', (
    WidgetTester tester,
  ) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final List<Task> seeded = <Task>[
      Task(id: 9, title: '英语听说作业', type: TaskType.todo, dueDate: today),
    ];
    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'r1',
            name: 'query',
            argumentsJson: '{"action":"tasks","filter":"uncompleted"}',
          ),
        ],
        finishReason: 'tool_calls',
      ),
      // 查到了数据，模型却只回两个字（真机现象）。
      const LlmChatResult(content: '这个', finishReason: 'stop'),
    ];

    await tester.pumpWidget(
      harness(
        chat: chat,
        taskRepo: taskRepo,
        settings: FakeSettingsRepository(<String, String>{'ai.onboarded': '1'}),
        tasks: seeded,
        turns: turns,
      ),
    );
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.enterText(find.byType(TextField), '我这个月还有什么没做完的');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    // 强制成文再问一次后仍然不行：不替模型编答案，也不把原始 JSON 倒给用户，
    // 只说明「查到了但没整理成话」（真机 2026-11-02：模型查到 3 条却只回「这个」）。
    expect(find.textContaining('我查到了数据，但没能把它整理成一句话'), findsOneWidget);
    final int sid = (await chat.listSessions()).single.id!;
    final String stored = chat.messagesOf(sid).last.content;
    expect(stored, isNot('这个'));
    expect(stored, isNot(contains('filter')));
  });

  testWidgets('AI：查完只回几个字时，强制整理成文能拿到真正的结论（2026-11-02 回归）', (
    WidgetTester tester,
  ) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final List<Task> seeded = <Task>[
      Task(id: 9, title: '英语听说作业', type: TaskType.todo, dueDate: today),
    ];
    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'r1',
            name: 'query',
            argumentsJson: '{"action":"tasks","filter":"uncompleted"}',
          ),
        ],
        finishReason: 'tool_calls',
      ),
      // 真机现象：查出 3 条，模型只回两个字。
      const LlmChatResult(content: '这个', finishReason: 'stop'),
      // 强制成文那一轮（不提供工具），模型终于把结果整理成了话。
      const LlmChatResult(
        content: '本月还有 1 条没做完：英语听说作业（10月7日到期）。',
        finishReason: 'stop',
      ),
    ];

    await tester.pumpWidget(
      harness(
        chat: chat,
        taskRepo: taskRepo,
        settings: FakeSettingsRepository(<String, String>{'ai.onboarded': '1'}),
        tasks: seeded,
        turns: turns,
      ),
    );
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.enterText(find.byType(TextField), '我这个月还有什么没做完的');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    // 用户拿到的是结论，不是「这个」，也不是兜底提示或原始 JSON。
    expect(find.textContaining('本月还有 1 条没做完'), findsOneWidget);
    expect(find.textContaining('我查到了数据，但没能把它整理成一句话'), findsNothing);
    final int sid = (await chat.listSessions()).single.id!;
    final String stored = chat.messagesOf(sid).last.content;
    expect(stored, contains('本月还有 1 条没做完'));
    expect(stored, isNot(contains('filter')));
  });

  testWidgets('AI：S7 防重——相同写调用重复发起不二次弹窗、不重复执行', (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final DateTime tomorrow = DateTime.now().add(const Duration(days: 1));
    final String tomorrowStr =
        '${tomorrow.year.toString().padLeft(4, '0')}-'
        '${tomorrow.month.toString().padLeft(2, '0')}-'
        '${tomorrow.day.toString().padLeft(2, '0')}';
    final Map<String, dynamic> args = <String, dynamic>{
      'action': 'create',
      'title': '交高数作业',
      'type': 'todo',
      'due_date': tomorrowStr,
    };
    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'w1',
            name: 'save_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'create',
              ...args,
            }),
          ),
        ],
        finishReason: 'tool_calls',
      ),
      // 模型重复发起完全相同的调用（异常行为）。
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'w2',
            name: 'save_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'create',
              ...args,
            }),
          ),
        ],
        finishReason: 'tool_calls',
      ),
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
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
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

    // 只写不查时确认完就收尾，不再向模型要复述（B）：因此这次重复调用
    // 根本不会发生——用户看到的结果行同样只有一条，不会重复。
    final int sessionId = (await chat.listSessions()).single.id!;
    final List<ChatMessage> toolMsgs = chat
        .messagesOf(sessionId)
        .where((ChatMessage m) => m.role == ChatRole.tool)
        .toList();
    expect(toolMsgs, hasLength(1));
    expect(toolMsgs[0].content, contains('"created"'));
    expect(find.text('已创建。'), findsNothing);
    expect(find.textContaining('已完成：新建待办任务「交高数作业」'), findsOneWidget);
  });

  testWidgets('AI：S7 参数自纠——无效调用不弹窗直接报错，修正后才确认一次', (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final DateTime tomorrow = DateTime.now().add(const Duration(days: 1));
    final String tomorrowStr =
        '${tomorrow.year.toString().padLeft(4, '0')}-'
        '${tomorrow.month.toString().padLeft(2, '0')}-'
        '${tomorrow.day.toString().padLeft(2, '0')}';
    final List<LlmChatResult> turns = <LlmChatResult>[
      // 第一次：缺 due_date（参数无效）→ 不弹窗，直接 error。
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'w1',
            name: 'save_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'create',
              'title': '交高数作业',
            }),
          ),
        ],
        finishReason: 'tool_calls',
      ),
      // 第二次：补全参数 → 弹窗确认一次。
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'w2',
            name: 'save_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'create',
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
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
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

  testWidgets('AI：提醒时刻——「8点提醒我」建的日程带每日提醒（remind_time）', (
    WidgetTester tester,
  ) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final DateTime tomorrow = DateTime.now().add(const Duration(days: 1));
    final String dueStr =
        '${tomorrow.year.toString().padLeft(4, '0')}-'
        '${tomorrow.month.toString().padLeft(2, '0')}-'
        '${tomorrow.day.toString().padLeft(2, '0')}';
    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'r1',
            name: 'save_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'create',
              'title': '交高数作业',
              'due_date': dueStr,
              'remind_time': '08:00',
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
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.enterText(find.byType(TextField), '明天8点提醒我交高数作业');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 确认面板写明提醒时刻，用户可核对。
    expect(find.textContaining('每天 08:00 提醒'), findsOneWidget);

    await tester.tap(find.text('执行选中项（1）'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(taskRepo.taskCount, 1);
    final Task saved = (await taskRepo.getTasks()).single;
    // 关键：落到与界面一致的「每日提醒时刻」，而非旧的截止偏移——
    // 旧偏移在无 due_time 时会被调度器算成当天 00:00 并因过期而取消，
    // 表现为「AI 建的日程没有提醒」。
    expect(saved.dailyRemindTime, '08:00');
    expect(saved.remindOffsetMin, isNull);
  });

  testWidgets('AI：S7 修改日程——save_task(update) 确认后按字段部分更新', (
    WidgetTester tester,
  ) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final DateTime due = DateTime.now().add(const Duration(days: 1));
    taskRepo.seed(
      Task(id: 1, title: '交高数作业', type: TaskType.todo, dueDate: due),
    );

    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'u1',
            name: 'save_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'update',
              'task_id': 1,
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
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
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

    // 字段部分更新：优先级变了，标题/类型/日期保持。
    expect(taskRepo.taskCount, 1);
    final Task updated = (await taskRepo.getTasks()).single;
    expect(updated.title, '交高数作业');
    expect(updated.type, TaskType.todo);
    expect(_sameDayOf(updated.dueDate, due), isTrue);
    expect(updated.priority, Priority.urgent);
    // 只写不查：结果行即答复，不再等模型复述一轮。
    expect(find.textContaining('已完成：修改「交高数作业」'), findsOneWidget);
    expect(find.text('已修改。'), findsNothing);
  });

  testWidgets('AI：S7 完成——save_task(complete) 把任务标记完成时播放完成提示音', (
    WidgetTester tester,
  ) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final DateTime due = DateTime.now().add(const Duration(days: 1));
    taskRepo.seed(
      Task(id: 1, title: '交高数作业', type: TaskType.todo, dueDate: due),
    );
    final _SoundRecorder sound = _SoundRecorder();
    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'c1',
            name: 'save_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'complete',
              'task_id': 1,
              'completed': true,
            }),
          ),
        ],
        finishReason: 'tool_calls',
      ),
      const LlmChatResult(content: '已标记完成。', finishReason: 'stop'),
    ];

    await tester.pumpWidget(
      harness(
        chat: chat,
        taskRepo: taskRepo,
        settings: FakeSettingsRepository(<String, String>{
          'ai.onboarded': '1',
          'ai.write_enabled': 'true',
          'notify.complete_sound': '/snd/complete.mp3',
        }),
        turns: turns,
        sound: sound,
      ),
    );
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.enterText(find.byType(TextField), '把交高数作业标成完成');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 确认面板出现并执行。
    expect(find.text('AI 请求修改数据'), findsOneWidget);
    expect(find.textContaining('标记为已完成'), findsOneWidget);
    await tester.tap(find.text('执行选中项（1）'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    // 任务完成且播了一次完成提示音。
    expect((await taskRepo.getTasks()).single.completed, isTrue);
    expect(sound.paths, <String>['/snd/complete.mp3']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI：S7 修改课程——save_course(update) 确认后更新并回传', (
    WidgetTester tester,
  ) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTimetableRepository timetableRepo = FakeTimetableRepository();
    timetableRepo.seedCourse(
      const Course(
        id: 1,
        semesterId: 1,
        name: '高等数学',
        location: '教一101',
        weekday: 2,
        startPeriod: 1,
        endPeriod: 2,
        endWeek: 14,
      ),
    );

    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'c1',
            name: 'save_course',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'update',
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
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
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
    expect(find.textContaining('已完成：修改课程「高等数学」'), findsOneWidget);
    expect(find.text('已修改课程。'), findsNothing);
  });

  testWidgets('AI：S8 批量草稿——一轮并行多条创建一次确认落库', (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final DateTime tomorrow = DateTime.now().add(const Duration(days: 1));
    final String tomorrowStr =
        '${tomorrow.year.toString().padLeft(4, '0')}-'
        '${tomorrow.month.toString().padLeft(2, '0')}-'
        '${tomorrow.day.toString().padLeft(2, '0')}';
    final List<LlmChatResult> turns = <LlmChatResult>[
      // 一条回复里并行发起两条 save_task(create)（批量计划场景）。
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'b1',
            name: 'save_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'create',
              'title': '周一开班会',
              'type': 'scheduled',
              'due_date': tomorrowStr,
              'due_time': '09:00',
            }),
          ),
          AiToolCall(
            id: 'b2',
            name: 'save_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'create',
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
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
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
    expect(
      tasks.map((Task t) => t.title),
      containsAll(<String>['周一开班会', '周三交实验报告']),
    );
    final int sessionId = (await chat.listSessions()).single.id!;
    final List<ChatMessage> toolMsgs = chat
        .messagesOf(sessionId)
        .where((ChatMessage m) => m.role == ChatRole.tool)
        .toList();
    expect(toolMsgs, hasLength(2));
    expect(toolMsgs[0].content, contains('"created"'));
    expect(toolMsgs[1].content, contains('"created"'));
  });

  testWidgets('AI：S8 草稿编辑——确认面板内改标题后按新内容落库', (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final DateTime tomorrow = DateTime.now().add(const Duration(days: 1));
    final String tomorrowStr =
        '${tomorrow.year.toString().padLeft(4, '0')}-'
        '${tomorrow.month.toString().padLeft(2, '0')}-'
        '${tomorrow.day.toString().padLeft(2, '0')}';
    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'e1',
            name: 'save_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'create',
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
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
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

  testWidgets('AI：S10 带图发送——面板选图附带输入框，随消息落库并进 wire', (
    WidgetTester tester,
  ) async {
    final FakeChatRepository chat = FakeChatRepository();
    final List<AiMessage> wires = <AiMessage>[];
    // 临时图片文件（data URI 需真实读取）。
    // fake-async 测试区内只能用同步 IO。
    final Directory tempDir = Directory.systemTemp.createTempSync('plai_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final List<String> realPaths = <String>[];
    for (int i = 0; i < 2; i++) {
      final File f = File('${tempDir.path}/photo_$i.jpg');
      f.writeAsBytesSync(kThumbBytes);
      realPaths.add(f.path);
    }

    await tester.pumpWidget(
      harness(
        chat: chat,
        settings: FakeSettingsRepository(<String, String>{'ai.onboarded': '1'}),
        onWire: wires.addAll,
        gallery: FakeGallerySource(paths: realPaths),
      ),
    );
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();

    // 打开「+」面板 → 点选一张照片 → 「添加所选（1）」附到输入框。
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('ai_gallery_photo_photo_0')),
    );
    await tester.pump();
    await tester.tap(find.text('添加所选（1）'));
    await tester.pumpAndSettle();
    expect(find.text('添加所选（1）'), findsNothing); // 面板收起
    // 预览条出现（缩略图占位/图片）。
    expect(find.byTooltip('发送'), findsOneWidget);

    // 输入要求并发送。
    await openInitialAiChat(tester);
    await tester.enterText(find.byType(TextField), '帮我核对课表');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    // 落库：user 消息带 attachments（Fake 透传）。
    final int sessionId = (await chat.listSessions()).single.id!;
    final ChatMessage userMsg = chat
        .messagesOf(sessionId)
        .firstWhere((ChatMessage m) => m.role == ChatRole.user);
    expect(userMsg.content, '帮我核对课表');
    expect(userMsg.attachments, isNotEmpty);

    // wire：最后一条 user 为多模态（图片 + 文本）。
    final AiMessage lastUser = wires.lastWhere(
      (AiMessage m) => m.role == AiRole.user,
    );
    expect(lastUser.parts, isNotNull);
    expect(lastUser.parts!.whereType<AiImagePart>(), isNotEmpty);
    expect(lastUser.parts!.whereType<AiTextPart>().single.text, '帮我核对课表');

    // 发送后预览条清空（无 pending 图片格）。
    expect(find.text('添加所选（1）'), findsNothing);
  });

  testWidgets('AI：S9 save_course(create)——课程落入当前学期，草稿编辑生效', (
    WidgetTester tester,
  ) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTimetableRepository timetableRepo = FakeTimetableRepository();
    timetableRepo.seedSemester(
      Semester(
        id: 1,
        name: '2026 秋',
        startDate: DateTime(2026, 8, 31),
        totalWeeks: 16,
      ),
    );

    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'cc1',
            name: 'save_course',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'create',
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
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
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
      find.widgetWithText(TextFormField, '教室（可留空）'),
      '教二303',
    );
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

  // ------------------------------------------------ S11 删除（save_task / save_course 的 delete）

  /// 删除类用例的公共发送流程：发送一句话 → 推进到确认面板/工具结果。
  Future<void> sendAndSettle(WidgetTester tester, String text) async {
    await openInitialAiChat(tester);
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 确认面板里点「执行选中项」并等工具轮跑完。
  Future<void> tapExecute(WidgetTester tester) async {
    await tester.tap(find.text('执行选中项（1）'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
  }

  /// 会话里首条 tool 结果消息（回传给模型的执行结果 JSON）。
  Future<String> firstToolOutput(FakeChatRepository chat) async {
    final int sessionId = (await chat.listSessions()).single.id!;
    return chat
        .messagesOf(sessionId)
        .firstWhere((ChatMessage m) => m.role == ChatRole.tool)
        .content;
  }

  testWidgets('AI：S11 删除日程——卡片指名道姓，确认后删除并取消其提醒', (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final FakeScheduler scheduler = FakeScheduler();
    taskRepo.seed(
      Task(
        id: 7,
        title: '交高数作业',
        type: TaskType.todo,
        dueDate: DateTime.now().add(const Duration(days: 3)),
        dailyRemindTime: '08:00',
      ),
    );
    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'd1',
            name: 'save_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'delete',
              'task_id': 7,
            }),
          ),
        ],
        finishReason: 'tool_calls',
      ),
      const LlmChatResult(content: '已删除。', finishReason: 'stop'),
    ];

    await tester.pumpWidget(
      harness(
        chat: chat,
        taskRepo: taskRepo,
        scheduler: scheduler,
        settings: FakeSettingsRepository(<String, String>{
          'ai.onboarded': '1',
          'ai.write_enabled': 'true',
        }),
        turns: turns,
      ),
    );
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await sendAndSettle(tester, '把交高数作业删了');

    // 确认卡片：指名道姓 + 明确不可恢复；删除无可改字段，故不提供草稿编辑。
    expect(find.text('AI 请求修改数据'), findsOneWidget);
    expect(find.textContaining('删除日程「交高数作业」'), findsOneWidget);
    expect(find.textContaining('不可恢复'), findsOneWidget);
    expect(find.byTooltip('编辑这条草稿'), findsNothing);

    await tapExecute(tester);

    expect(taskRepo.taskCount, 0);
    expect(
      scheduler.cancelled,
      contains('task:7'),
      reason: '删除须一并取消该任务提醒，否则留下幽灵通知',
    );
    expect(await firstToolOutput(chat), contains('"deleted"'));
    expect(find.textContaining('已完成：删除'), findsOneWidget);
    expect(find.text('已删除。'), findsNothing);
  });

  testWidgets('AI：S11 删除日程——取消勾选则不执行，任务保留', (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final FakeScheduler scheduler = FakeScheduler();
    taskRepo.seed(
      Task(
        id: 7,
        title: '交高数作业',
        type: TaskType.todo,
        dueDate: DateTime.now().add(const Duration(days: 3)),
      ),
    );
    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'd1',
            name: 'save_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'delete',
              'task_id': 7,
            }),
          ),
        ],
        finishReason: 'tool_calls',
      ),
      const LlmChatResult(content: '已取消。', finishReason: 'stop'),
    ];

    await tester.pumpWidget(
      harness(
        chat: chat,
        taskRepo: taskRepo,
        scheduler: scheduler,
        settings: FakeSettingsRepository(<String, String>{
          'ai.onboarded': '1',
          'ai.write_enabled': 'true',
        }),
        turns: turns,
      ),
    );
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await sendAndSettle(tester, '把交高数作业删了');

    await tester.tap(find.text('全部跳过'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(taskRepo.taskCount, 1);
    expect(scheduler.cancelled, isEmpty);
    expect(await firstToolOutput(chat), contains('"skipped"'));
  });

  testWidgets('AI：S11 删除课程——卡片带星期/节次/教室，确认后整门删除', (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTimetableRepository timetableRepo = FakeTimetableRepository();
    final FakeScheduler scheduler = FakeScheduler();
    timetableRepo.seedCourse(
      const Course(
        id: 3,
        semesterId: 1,
        name: '大学英语',
        weekday: 2,
        startPeriod: 3,
        endPeriod: 4,
        location: '外语楼201',
      ),
    );
    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'dc1',
            name: 'save_course',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'delete',
              'course_id': 3,
            }),
          ),
        ],
        finishReason: 'tool_calls',
      ),
      const LlmChatResult(content: '已删除该课程。', finishReason: 'stop'),
    ];

    await tester.pumpWidget(
      harness(
        chat: chat,
        timetableRepo: timetableRepo,
        scheduler: scheduler,
        settings: FakeSettingsRepository(<String, String>{
          'ai.onboarded': '1',
          'ai.write_enabled': 'true',
        }),
        turns: turns,
      ),
    );
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await sendAndSettle(tester, '把大学英语删了');

    // 同名课（单双周/不同教室）靠星期节次教室才能分清，卡片必须带上。
    expect(find.textContaining('删除课程「大学英语」'), findsOneWidget);
    expect(find.textContaining('周二 3-4节'), findsOneWidget);
    expect(find.textContaining('外语楼201'), findsOneWidget);

    await tapExecute(tester);

    expect(timetableRepo.courseCount, 0);
    expect(scheduler.cancelled, contains('course:3'), reason: '删除课程须取消其全部上课提醒');
    expect(await firstToolOutput(chat), contains('"deleted"'));
  });

  testWidgets('AI：S11 删除口径——task_id 非法不弹面板，直接回错让模型自纠', (
    WidgetTester tester,
  ) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    taskRepo.seed(
      Task(id: 7, title: '交高数作业', type: TaskType.todo, dueDate: DateTime.now()),
    );
    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'd1',
            name: 'save_task',
            // 模型常见的错法：直接拿标题当 id。
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'delete',
              'task_id': '交高数作业',
            }),
          ),
        ],
        finishReason: 'tool_calls',
      ),
      const LlmChatResult(content: '信息不完整，已跳过。', finishReason: 'stop'),
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
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await sendAndSettle(tester, '把交高数作业删了');
    await tester.pumpAndSettle();

    // 参数无效 → 不弹确认面板（不让用户看到注定失败的确认），直接回 error。
    expect(find.text('AI 请求修改数据'), findsNothing);
    expect(taskRepo.taskCount, 1);
    expect(await firstToolOutput(chat), contains('"error"'));
  });

  testWidgets('AI：S11 删除口径——id 不存在时卡片标未找到，执行后回 not_found 不误删', (
    WidgetTester tester,
  ) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    taskRepo.seed(
      Task(id: 7, title: '交高数作业', type: TaskType.todo, dueDate: DateTime.now()),
    );
    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'd1',
            name: 'save_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'delete',
              'task_id': 999,
            }),
          ),
        ],
        finishReason: 'tool_calls',
      ),
      const LlmChatResult(content: '没找到这条。', finishReason: 'stop'),
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
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await sendAndSettle(tester, '把那条删了');

    expect(find.textContaining('未找到该日程'), findsOneWidget);

    await tapExecute(tester);

    expect(await firstToolOutput(chat), contains('"not_found"'));
    expect(taskRepo.taskCount, 1, reason: 'id 不存在时不得误删其它任务');
  });

  // ------------------------------------------------ 改色端到端（弹窗→落库→渲染）

  /// 建 in-memory 测试库 —— **必须用 `databaseFactoryFfiNoIsolate`**
  /// （默认工厂跑后台 isolate，假时钟下 Future 永不完成 → 用例挂死，
  /// 详见 `timetable_page_test.dart` 文件头注释）。
  Future<(ITimetableRepository, ISettingsRepository)> newRealRepos() async {
    sqfliteFfiInit();
    final AppDatabase db = AppDatabase(
      factory: databaseFactoryFfiNoIsolate,
      path: inMemoryDatabasePath,
    );
    await db.database; // 触发 onCreate 建表
    addTearDown(() => db.close());
    return (TimetableRepository(db), SettingsRepository(db));
  }

  /// 周视图里课程色块**实际解析出的**渲染色（逐节；无色节为 null 被滤掉）。
  ///
  /// [skipOffstage] = false 可看到被 IndexedStack 下架的那一 tab 的内容，
  /// 用于验证「用户还没切回课表 tab，背后的课表其实已经重绘」。
  List<Color> renderedBlockColors(
    WidgetTester tester, {
    bool skipOffstage = true,
  }) {
    final List<Color> out = <Color>[];
    for (final SegmentedCourseBlock block
        in tester.widgetList<SegmentedCourseBlock>(
          find.byType(SegmentedCourseBlock, skipOffstage: skipOffstage),
        )) {
      out.addAll(block.perPeriodColors.whereType<Color>());
    }
    return out;
  }

  /// 色块真实的背景填充色（逐节 `色@0.16`）——比读 widget 字段更贴近画面。
  bool blockPaintedWith(
    WidgetTester tester,
    Color color, {
    bool skipOffstage = true,
  }) {
    for (final Container c in tester.widgetList<Container>(
      find.descendant(
        of: find.byType(SegmentedCourseBlock, skipOffstage: skipOffstage),
        matching: find.byType(Container, skipOffstage: skipOffstage),
      ),
    )) {
      if (c.color == color.withValues(alpha: 0.16)) return true;
    }
    return false;
  }

  /// 改色 e2e 的公共装配：真实数据层 + 课表页/AI 页同树（IndexedStack），
  /// 学期第 1 周 = 本周，课程排在**非今天**那一列（今天列会被状态色覆盖，
  /// 用非今天列才能验证「课程自选色」这条链）。
  Future<({ITimetableRepository timetable, int courseId})> mountColorE2e(
    WidgetTester tester, {
    required List<LlmChatResult> Function(int courseId) turnsOf,
    required ValueNotifier<int> tab,
    String seededColor = '#E57373',
  }) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final (ITimetableRepository timetable, ISettingsRepository settings) =
        await newRealRepos();
    final DateTime now = DateTime.now();
    final int weekday = now.weekday == 1 ? 2 : 1;
    final int semesterId = await timetable.insertSemester(
      Semester(
        name: '2026 秋',
        startDate: DateTime(now.year, now.month, now.day),
        totalWeeks: 16,
      ),
    );
    final int courseId = await timetable.insertCourse(
      Course(
        semesterId: semesterId,
        name: '高等数学',
        teacher: '张老师',
        location: '教一101',
        color: seededColor,
        weekday: weekday,
        startPeriod: 1,
        endPeriod: 2,
        startWeek: 1,
        endWeek: 16,
      ),
    );
    await settings.setValue('ai.onboarded', '1');
    await settings.setValue('ai.write_enabled', 'true');

    final FakeChatRepository chat = FakeChatRepository();
    await tester.pumpWidget(
      harness(
        chat: chat,
        settings: settings,
        timetableRepo: timetable,
        turns: turnsOf(courseId),
        // 课表页与 AI 页同树常驻（对齐 AppShell 的 IndexedStack），
        // 切 tab 不是重启、不重建 ProviderScope。
        home: ValueListenableBuilder<int>(
          valueListenable: tab,
          builder: (BuildContext context, int index, Widget? _) => IndexedStack(
            index: index,
            children: const <Widget>[TimetablePage(), AiPage()],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    return (timetable: timetable, courseId: courseId);
  }

  /// 在 AI tab 发起一句请求并推进到确认面板（占位行转圈期间用固定时长推动画）。
  Future<void> sendOnAiTab(
    WidgetTester tester,
    ValueNotifier<int> tab,
    String text,
  ) async {
    tab.value = 1;
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 点「执行选中项」并等工具轮跑完（此时仍停在 AI tab）。
  Future<void> executeSelected(WidgetTester tester) async {
    await tester.tap(find.text('执行选中项（1）'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
  }

  /// 切回课表 tab（IndexedStack 换 index，不重启、不重建 ProviderScope）。
  Future<void> backToTimetable(
    WidgetTester tester,
    ValueNotifier<int> tab,
  ) async {
    tab.value = 0;
    await tester.pumpAndSettle();
  }

  testWidgets('AI：改色 e2e——弹窗文案可读 → 确认落库 → 课表色块立刻变色', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<int> tab = ValueNotifier<int>(0); // 0=课表 1=AI
    addTearDown(tab.dispose);

    final ({ITimetableRepository timetable, int courseId}) env =
        await mountColorE2e(
          tester,
          tab: tab,
          turnsOf: (int courseId) => <LlmChatResult>[
            LlmChatResult(
              toolCalls: <AiToolCall>[
                AiToolCall(
                  id: 'c1',
                  name: 'save_course',
                  argumentsJson: jsonEncode(<String, dynamic>{
                    'action': 'update',
                    'course_id': courseId,
                    'color': '蓝色',
                  }),
                ),
              ],
              finishReason: 'tool_calls',
            ),
            const LlmChatResult(content: '已把高等数学改成蓝色。', finishReason: 'stop'),
          ],
        );

    // 前置基线：课表视图此刻渲染的就是种下的红色（证明链路起点是活的）。
    expect(renderedBlockColors(tester), contains(const Color(0xFFE57373)));
    expect(blockPaintedWith(tester, const Color(0xFFE57373)), isTrue);

    await sendOnAiTab(tester, tab, '把高等数学改成蓝色');

    // ① 确认弹窗里的颜色文案逐字可读（describe → 弹窗条目直接展示）。
    expect(find.text('AI 请求修改数据'), findsOneWidget);
    expect(find.textContaining('修改课程「高等数学」'), findsOneWidget);
    expect(find.textContaining('颜色：蓝色（#64B5F6）'), findsOneWidget);

    await executeSelected(tester);

    // ② 落库（读回验证）：写的是归一化后的大写带 # 色值。
    final Course saved = (await env.timetable.getCourseById(env.courseId))!;
    expect(saved.color, '#64B5F6');
    // 回归防线：未被 AI 触碰的字段一律不得被 copyWith 带歪。
    expect(saved.name, '高等数学');
    expect(saved.teacher, '张老师');
    expect(saved.location, '教一101');
    expect(saved.weekday, isNot(DateTime.now().weekday));
    expect(saved.startPeriod, 1);
    expect(saved.endPeriod, 2);
    expect(saved.startWeek, 1);
    expect(saved.endWeek, 16);
    expect(saved.weekType, WeekType.every);
    expect(saved.weekList, isEmpty);
    expect(saved.semesterId, isNotNull);

    // ③ 课表视图**立刻**重绘：此刻用户还停在 AI tab，背后的课表（IndexedStack
    //    下架状态）已经换成新色——说明是 execute 里的 `ref.invalidate(
    //    coursesProvider)` 生效，而不是切 tab 时重建/重读才变。
    expect(
      renderedBlockColors(tester, skipOffstage: false),
      contains(const Color(0xFF64B5F6)),
    );
    expect(
      renderedBlockColors(tester, skipOffstage: false),
      isNot(contains(const Color(0xFFE57373))),
    );
    expect(
      blockPaintedWith(tester, const Color(0xFF64B5F6), skipOffstage: false),
      isTrue,
    );

    // ④ 切回课表 tab：同一棵树、未重启，色块即所见即所得。
    await backToTimetable(tester, tab);
    expect(renderedBlockColors(tester), contains(const Color(0xFF64B5F6)));
    expect(
      renderedBlockColors(tester),
      isNot(contains(const Color(0xFFE57373))),
    );
    expect(blockPaintedWith(tester, const Color(0xFF64B5F6)), isTrue);
    expect(blockPaintedWith(tester, const Color(0xFFE57373)), isFalse);

    // 收尾：卸载（取消 WeekView 的周期定时器）。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
  });

  testWidgets('AI：改色 e2e（边界）——「无色」显示「清除颜色」→ 落库空串 → 色块转中性', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<int> tab = ValueNotifier<int>(0);
    addTearDown(tab.dispose);

    final ({ITimetableRepository timetable, int courseId}) env =
        await mountColorE2e(
          tester,
          tab: tab,
          turnsOf: (int courseId) => <LlmChatResult>[
            LlmChatResult(
              toolCalls: <AiToolCall>[
                AiToolCall(
                  id: 'c1',
                  name: 'save_course',
                  argumentsJson: jsonEncode(<String, dynamic>{
                    'action': 'update',
                    'course_id': courseId,
                    'color': '无色',
                  }),
                ),
              ],
              finishReason: 'tool_calls',
            ),
            const LlmChatResult(content: '已清除颜色。', finishReason: 'stop'),
          ],
        );

    expect(renderedBlockColors(tester), contains(const Color(0xFFE57373)));

    await sendOnAiTab(tester, tab, '把高等数学的颜色去掉');

    expect(find.textContaining('清除颜色'), findsOneWidget);
    expect(find.textContaining('颜色：'), findsNothing);

    await executeSelected(tester);

    final Course saved = (await env.timetable.getCourseById(env.courseId))!;
    expect(saved.color, '');
    expect(saved.name, '高等数学'); // 只清除颜色，其余字段不动。

    // 课表视图立刻转中性（无色节 → perPeriodColors 全 null，不按红色渲染）。
    expect(
      renderedBlockColors(tester, skipOffstage: false),
      isNot(contains(const Color(0xFFE57373))),
    );
    expect(renderedBlockColors(tester, skipOffstage: false), isEmpty);
    expect(
      blockPaintedWith(tester, const Color(0xFFE57373), skipOffstage: false),
      isFalse,
    );

    await backToTimetable(tester, tab);
    expect(renderedBlockColors(tester), isEmpty);
    expect(blockPaintedWith(tester, const Color(0xFFE57373)), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
  });

  testWidgets('AI：改色 e2e（多字段）——与其它字段同批改动时颜色行仍完整可读', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<int> tab = ValueNotifier<int>(0);
    addTearDown(tab.dispose);

    final ({ITimetableRepository timetable, int courseId}) env =
        await mountColorE2e(
          tester,
          tab: tab,
          turnsOf: (int courseId) => <LlmChatResult>[
            LlmChatResult(
              toolCalls: <AiToolCall>[
                AiToolCall(
                  id: 'c1',
                  name: 'save_course',
                  argumentsJson: jsonEncode(<String, dynamic>{
                    'action': 'update',
                    'course_id': courseId,
                    'location': '教二202',
                    'color': '蓝色',
                  }),
                ),
              ],
              finishReason: 'tool_calls',
            ),
            const LlmChatResult(content: '已修改。', finishReason: 'stop'),
          ],
        );

    await sendOnAiTab(tester, tab, '高数换到教二202，顺便改成蓝色');

    // 同一张确认卡上两条改动都在，颜色行没被挤掉/截断。
    final Finder card = find.textContaining('修改课程「高等数学」');
    expect(card, findsOneWidget);
    expect(find.textContaining('教室 → 教二202'), findsOneWidget);
    expect(find.textContaining('颜色：蓝色（#64B5F6）'), findsOneWidget);
    // 逐字核验整条文案（多字段以「；」分隔，不换行截断）。
    expect(
      tester.widget<Text>(card).data,
      '修改课程「高等数学」：教室 → 教二202；颜色：蓝色（#64B5F6）',
    );

    await executeSelected(tester);

    final Course saved = (await env.timetable.getCourseById(env.courseId))!;
    expect(saved.location, '教二202');
    expect(saved.color, '#64B5F6');
    expect(saved.teacher, '张老师');
    expect(
      renderedBlockColors(tester, skipOffstage: false),
      contains(const Color(0xFF64B5F6)),
    );

    await backToTimetable(tester, tab);
    expect(renderedBlockColors(tester), contains(const Color(0xFF64B5F6)));
    expect(find.text('教二202'), findsOneWidget); // 色块上的地点也同步更新。

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
  });

  // ------------------------------------------------ 确认卡颜色预览色块

  /// 确认卡上颜色预览色块的颜色；无色块时返回 null。
  Color? swatchColorOf(WidgetTester tester) {
    final Finder f = find.byKey(const Key('ai-write-swatch'));
    if (f.evaluate().isEmpty) return null;
    final Container box = tester.widget<Container>(f);
    return (box.decoration as BoxDecoration?)?.color;
  }

  /// 单一 save_course(update) 调用的最小装配（只关心确认卡，无需课表页）。
  Future<void> mountSwatchCase(
    WidgetTester tester, {
    required List<LlmChatResult> Function(int courseId) turnsOf,
  }) async {
    final ValueNotifier<int> tab = ValueNotifier<int>(0);
    addTearDown(tab.dispose);
    await mountColorE2e(tester, tab: tab, turnsOf: turnsOf);
    await sendOnAiTab(tester, tab, '改一下课程');
  }

  testWidgets('AI：色块预览——色名「蓝色」→ 色块为 #64B5F6', (WidgetTester tester) async {
    await mountSwatchCase(
      tester,
      turnsOf: (int id) => <LlmChatResult>[
        LlmChatResult(
          toolCalls: <AiToolCall>[
            AiToolCall(
              id: 'c1',
              name: 'save_course',
              argumentsJson: jsonEncode(<String, dynamic>{
                'action': 'update',
                'course_id': id,
                'color': '蓝色',
              }),
            ),
          ],
          finishReason: 'tool_calls',
        ),
        const LlmChatResult(content: '好的。', finishReason: 'stop'),
      ],
    );

    expect(find.textContaining('颜色：蓝色（#64B5F6）'), findsOneWidget);
    expect(swatchColorOf(tester), const Color(0xFF64B5F6));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
  });

  testWidgets('AI：色块预览——hex「#123456」→ 色块为 #123456', (
    WidgetTester tester,
  ) async {
    await mountSwatchCase(
      tester,
      turnsOf: (int id) => <LlmChatResult>[
        LlmChatResult(
          toolCalls: <AiToolCall>[
            AiToolCall(
              id: 'c1',
              name: 'save_course',
              argumentsJson: jsonEncode(<String, dynamic>{
                'action': 'update',
                'course_id': id,
                'color': '#123456',
              }),
            ),
          ],
          finishReason: 'tool_calls',
        ),
        const LlmChatResult(content: '好的。', finishReason: 'stop'),
      ],
    );

    expect(find.textContaining('颜色：#123456'), findsOneWidget);
    expect(swatchColorOf(tester), const Color(0xFF123456));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
  });

  testWidgets('AI：色块预览——「无色」清除颜色 → 无色块', (WidgetTester tester) async {
    await mountSwatchCase(
      tester,
      turnsOf: (int id) => <LlmChatResult>[
        LlmChatResult(
          toolCalls: <AiToolCall>[
            AiToolCall(
              id: 'c1',
              name: 'save_course',
              argumentsJson: jsonEncode(<String, dynamic>{
                'action': 'update',
                'course_id': id,
                'color': '无色',
              }),
            ),
          ],
          finishReason: 'tool_calls',
        ),
        const LlmChatResult(content: '好的。', finishReason: 'stop'),
      ],
    );

    expect(find.textContaining('清除颜色'), findsOneWidget);
    expect(find.byKey(const Key('ai-write-swatch')), findsNothing);
    expect(swatchColorOf(tester), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
  });

  testWidgets('AI：色块预览——只改教室（不涉及颜色）→ 无色块', (WidgetTester tester) async {
    await mountSwatchCase(
      tester,
      turnsOf: (int id) => <LlmChatResult>[
        LlmChatResult(
          toolCalls: <AiToolCall>[
            AiToolCall(
              id: 'c1',
              name: 'save_course',
              argumentsJson: jsonEncode(<String, dynamic>{
                'action': 'update',
                'course_id': id,
                'location': '教二202',
              }),
            ),
          ],
          finishReason: 'tool_calls',
        ),
        const LlmChatResult(content: '好的。', finishReason: 'stop'),
      ],
    );

    expect(find.textContaining('教室 → 教二202'), findsOneWidget);
    expect(find.byKey(const Key('ai-write-swatch')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
  });

  testWidgets('AI：色块预览——多字段（教室+颜色）有色块且文案逐字不截断', (WidgetTester tester) async {
    await mountSwatchCase(
      tester,
      turnsOf: (int id) => <LlmChatResult>[
        LlmChatResult(
          toolCalls: <AiToolCall>[
            AiToolCall(
              id: 'c1',
              name: 'save_course',
              argumentsJson: jsonEncode(<String, dynamic>{
                'action': 'update',
                'course_id': id,
                'location': '教二202',
                'color': '蓝色',
              }),
            ),
          ],
          finishReason: 'tool_calls',
        ),
        const LlmChatResult(content: '好的。', finishReason: 'stop'),
      ],
    );

    expect(swatchColorOf(tester), const Color(0xFF64B5F6));
    final Finder card = find.textContaining('修改课程「高等数学」');
    expect(card, findsOneWidget);
    expect(
      tester.widget<Text>(card).data,
      '修改课程「高等数学」：教室 → 教二202；颜色：蓝色（#64B5F6）',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
  });

  testWidgets('AI：色块预览——窄屏 + 大字体不溢出、文案不截断', (WidgetTester tester) async {
    // 只挂 AI 页（不挂课表页）：本次验收点是确认卡自身在极端字号/宽度下
    // 不溢出；课表页在其自身模块另有窄屏用例。
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final (ITimetableRepository timetable, ISettingsRepository settings) =
        await newRealRepos();
    final DateTime now = DateTime.now();
    final int semesterId = await timetable.insertSemester(
      Semester(
        name: '2026 秋',
        startDate: DateTime(now.year, now.month, now.day),
        totalWeeks: 16,
      ),
    );
    final int courseId = await timetable.insertCourse(
      Course(
        semesterId: semesterId,
        name: '高等数学',
        location: '教一101',
        color: '#E57373',
        weekday: 1,
        startPeriod: 1,
        endPeriod: 2,
        startWeek: 1,
        endWeek: 16,
      ),
    );
    await settings.setValue('ai.onboarded', '1');
    await settings.setValue('ai.write_enabled', 'true');

    await tester.pumpWidget(
      harness(
        chat: FakeChatRepository(),
        settings: settings,
        timetableRepo: timetable,
        turns: <LlmChatResult>[
          LlmChatResult(
            toolCalls: <AiToolCall>[
              AiToolCall(
                id: 'c1',
                name: 'save_course',
                argumentsJson: jsonEncode(<String, dynamic>{
                  'action': 'update',
                  'course_id': courseId,
                  'location': '教二202',
                  'color': '蓝色',
                }),
              ),
            ],
            finishReason: 'tool_calls',
          ),
          const LlmChatResult(content: '好的。', finishReason: 'stop'),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();

    await openInitialAiChat(tester);
    await tester.enterText(find.byType(TextField), '高数换教室并改成蓝色');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(swatchColorOf(tester), const Color(0xFF64B5F6));
    final Finder card = find.textContaining('修改课程「高等数学」');
    expect(card, findsOneWidget);
    // 整段文案逐字保留（未被截断/省略）。
    expect(
      tester.widget<Text>(card).data,
      '修改课程「高等数学」：教室 → 教二202；颜色：蓝色（#64B5F6）',
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
  });

  testWidgets('AI：提醒「只提醒一次」——remind_at 落成 once 并交给调度器', (
    WidgetTester tester,
  ) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final FakeScheduler scheduler = FakeScheduler();
    final DateTime tomorrow = DateTime.now().add(const Duration(days: 1));
    final String dueStr =
        '${tomorrow.year.toString().padLeft(4, '0')}-'
        '${tomorrow.month.toString().padLeft(2, '0')}-'
        '${tomorrow.day.toString().padLeft(2, '0')}';
    final String atStr = '$dueStr 09:30';
    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'r1',
            name: 'save_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'create',
              'title': '交高数作业',
              'type': 'todo',
              'due_date': dueStr,
              'remind_at': atStr,
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
        scheduler: scheduler,
        settings: FakeSettingsRepository(<String, String>{
          'ai.onboarded': '1',
          'ai.write_enabled': 'true',
        }),
        turns: turns,
      ),
    );
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.enterText(find.byType(TextField), '明天9点半提醒我一次交高数作业');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 确认卡文案带「提醒一次」，用户能看出不是每天重复。
    expect(find.textContaining('提醒一次'), findsOneWidget);

    await tester.tap(find.text('执行选中项（1）'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(taskRepo.taskCount, 1);
    final Task created = (await taskRepo.getTasks()).single;
    expect(created.reminderRepeat, ReminderRepeat.once);
    expect(created.remindOnceAt, DateTime.parse(atStr));
    expect(created.dailyRemindTime, isNull);
    // 只写不查：确认卡文案直接成为结果行，含「提醒一次」。
    expect(find.textContaining('已完成：新建待办任务「交高数作业」'), findsOneWidget);
    expect(find.text('已创建。'), findsNothing);
  });

  testWidgets('AI：草稿编辑框——两种提醒同时填时保存被拦下', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final DateTime tomorrow = DateTime.now().add(const Duration(days: 1));
    final String dueStr =
        '${tomorrow.year.toString().padLeft(4, '0')}-'
        '${tomorrow.month.toString().padLeft(2, '0')}-'
        '${tomorrow.day.toString().padLeft(2, '0')}';
    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'e2',
            name: 'save_task',
            argumentsJson: jsonEncode(<String, dynamic>{
              'action': 'create',
              'title': '交高数作业',
              'type': 'todo',
              'due_date': dueStr,
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
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.enterText(find.byType(TextField), '建个待办');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byTooltip('编辑这条草稿'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('编辑这条日程'), findsOneWidget);

    // 两行提醒都填上 → 保存按钮点了不关窗，并给出冲突说明。
    await tester.enterText(
      find.widgetWithText(TextFormField, '每天提醒时刻（HH:mm，留空=不提醒）'),
      '08:00',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '只提醒一次（yyyy-MM-dd HH:mm，留空=不用）'),
      '$dueStr 09:30',
    );
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('「每天提醒」与「只提醒一次」只能填一个'), findsWidgets);
    expect(find.text('编辑这条日程'), findsOneWidget);

    // 清掉每天 → 只留一次性 → 保存生效。
    await tester.enterText(
      find.widgetWithText(TextFormField, '每天提醒时刻（HH:mm，留空=不提醒）'),
      '',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('保存'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('编辑这条日程'), findsNothing);
    expect(find.textContaining('提醒一次'), findsOneWidget);

    await tester.tap(find.text('执行选中项（1）'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    final Task created = (await taskRepo.getTasks()).single;
    expect(created.reminderRepeat, ReminderRepeat.once);
    expect(created.remindOnceAt, DateTime.parse('$dueStr 09:30'));
    expect(created.dailyRemindTime, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
  });

  testWidgets('AI：写操作执行中——进度行说明「正在执行」，不含工具名', (WidgetTester tester) async {
    final FakeChatRepository chat = FakeChatRepository();
    final FakeTaskRepository taskRepo = FakeTaskRepository();
    final FakeScheduler scheduler = FakeScheduler();
    final List<LlmChatResult> turns = <LlmChatResult>[
      LlmChatResult(
        toolCalls: <AiToolCall>[
          AiToolCall(
            id: 'r1',
            name: 'save_task',
            argumentsJson:
                '{"action":"create","title":"买教材","type":"todo",'
                '"due_date":"2026-11-05"}',
          ),
        ],
        finishReason: 'tool_calls',
      ),
    ];

    await tester.pumpWidget(
      harness(
        chat: chat,
        taskRepo: taskRepo,
        scheduler: scheduler,
        settings: FakeSettingsRepository(<String, String>{
          'ai.onboarded': '1',
          'ai.write_enabled': 'true',
        }),
        turns: turns,
      ),
    );
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
    await tester.enterText(find.byType(TextField), '帮我建一条买教材');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // ① 确认面板弹着的时候，进度行不再是全程那句含糊的「正在查询…」，
    //    而且文案里不出现任何工具名 / 函数名。
    expect(find.text('执行选中项（1）'), findsOneWidget);
    expect(find.text('正在查询…'), findsNothing);
    expect(find.textContaining('save_task'), findsNothing);
    expect(find.textContaining('query'), findsNothing);

    await tester.tap(find.text('执行选中项（1）'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    // ② 全程跑完后所有进度文案都必须消失（残留会让用户以为还在跑）。
    for (final String stage in <String>[
      '正在思考…',
      '正在处理…',
      '准备修改…',
      '正在执行…',
      '正在整理结果…',
    ]) {
      expect(find.text(stage), findsNothing, reason: stage);
    }
    expect(taskRepo.taskCount, 1);
    // ③ 结果行立刻落库：不依赖模型那句收尾文字（这里根本没有第二轮，
    //    FakeLlmClient 用尽脚本后回的是无关的「已收到。」），
    //    用户点完确认就该看到「完成了什么」。
    expect(find.textContaining('已完成：'), findsOneWidget);
    expect(find.textContaining('买教材'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await openInitialAiChat(tester);
  });
}

bool _sameDayOf(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
