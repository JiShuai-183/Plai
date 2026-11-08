import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/data/models/chat_queue_entry.dart';
import 'package:plai/data/repositories/task_image_store.dart';
import 'package:plai/features/ai/ai_providers.dart';
import 'package:plai/features/ai/ai_queue_attachments.dart';
import 'package:plai/features/ai/ai_queue_providers.dart';
import 'package:plai/features/ai/ai_settings_keys.dart';
import 'package:plai/features/ai/ai_task_photos.dart';
import 'package:plai/features/ai/ai_tool_context.dart';
import 'package:plai/features/ai/ai_write_tools.dart';
import 'package:plai/features/schedule/schedule_providers.dart';
import 'package:plai/features/timetable/timetable_providers.dart';
import 'package:plai/services/ai/llm_client.dart';
import 'package:plai/services/ai/models/ai_tool.dart';
import 'package:plai/services/notifications/notification_providers.dart';

import 'ai_page_test.dart'
    show
        FakeTaskRepository,
        FakeScheduler,
        FakeChatRepository,
        FakeChatQueueRepository,
        FakeLlmClient,
        FakeSettingsRepository,
        FakeTimetableRepository;

/// Fail only the refresh after a successful write, not the proposal lookup.
class _Tasks extends FakeTaskRepository {
  bool failReadAfterWrite = false;
  bool _written = false;

  @override
  Future<int> insertTask(Task task) async {
    final id = await super.insertTask(task);
    _written = true;
    return id;
  }

  @override
  Future<int> updateTask(Task task) async {
    final changed = await super.updateTask(task);
    _written = changed == 1;
    return changed;
  }

  @override
  Future<Task?> getTaskById(int id) {
    if (failReadAfterWrite && _written) throw StateError('写后刷新失败');
    return super.getTaskById(id);
  }
}

void main() {
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
  );
  final tool = findAiWriteTool('save_task')!;
  late Directory temp;
  late TaskImageStore store;
  late _Tasks tasks;
  late ProviderContainer container;
  late List<String> sources;
  late List<String> releaseAttempts;
  late List<String> deleted;
  late FakeChatRepository chat;
  late FakeChatQueueRepository chatQueue;
  late AiQueueAttachments attachments;
  late List<String> wireSystemPrompts;

  AiToolContext request({List<String>? images, String id = 'queue:photo'}) =>
      AiToolContext(
        read: container.read,
        invalidate: container.invalidate,
      ).forRequest(
        requestId: id,
        imagePaths: images ?? sources,
        userText: '把本次图片附到日程',
      );
  Map<String, dynamic> create([Map<String, dynamic> fields = const {}]) => {
    'action': 'create',
    'title': '复习',
    'due_date': '2030-01-01',
    ...fields,
  };
  Map<String, dynamic> update([Map<String, dynamic> fields = const {}]) => {
    'action': 'update',
    'task_id': 1,
    ...fields,
  };
  Future<Map<String, dynamic>> execute(
    AiToolContext context,
    Map<String, dynamic> args,
  ) async => Map<String, dynamic>.from(
    jsonDecode(await tool.execute(context, args)) as Map,
  );
  Future<List<String>> seedOld(int count) async {
    final paths = <String>[];
    for (var i = 0; i < count; i++) {
      paths.add(await store.importFile(sources[i]));
    }
    tasks.seed(
      Task(
        id: 1,
        title: '旧任务',
        description: '旧描述',
        type: TaskType.todo,
        dueDate: DateTime(2030),
        imagePaths: paths,
      ),
    );
    return paths;
  }

  Future<List<FileSystemEntity>> copies() async {
    final directory = await store.directory;
    return await directory.exists() ? directory.list().toList() : [];
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('plai-ai-photo-execution-');
    sources = [];
    for (var i = 0; i < 4; i++) {
      final file = File('${temp.path}/chat$i.png');
      await file.writeAsBytes(png);
      sources.add(file.path);
    }
    store = TaskImageStore(directory: Directory('${temp.path}/task_images'));
    tasks = _Tasks();
    releaseAttempts = [];
    deleted = [];
    wireSystemPrompts = [];
    chat = FakeChatRepository();
    chatQueue = FakeChatQueueRepository(chat);
    attachments = AiQueueAttachments(
      directory: () async => Directory('${temp.path}/ai_queue'),
      prepare: (_) async => null,
    );
    container = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        chatQueueRepositoryProvider.overrideWithValue(chatQueue),
        aiQueueAttachmentsProvider.overrideWithValue(attachments),
        timetableRepositoryProvider.overrideWithValue(
          FakeTimetableRepository(),
        ),
        settingsRepositoryProvider.overrideWithValue(
          FakeSettingsRepository({AiSettingsKeys.writeEnabled: 'true'}),
        ),
        llmConfigProvider.overrideWith(
          (ref) async => const LlmConfig(
            enabled: true,
            baseUrl: 'https://example.invalid/v1',
            model: 'fake',
          ),
        ),
        llmClientFactoryProvider.overrideWith(
          (ref) =>
              ({
                required String baseUrl,
                String apiKey = '',
                required String model,
              }) => FakeLlmClient(
                baseUrl: baseUrl,
                model: model,
                onWire: (messages) =>
                    wireSystemPrompts.add(messages.first.text ?? ''),
                turns: [
                  LlmChatResult(
                    toolCalls: [
                      AiToolCall(
                        id: 'photo-create',
                        name: 'save_task',
                        argumentsJson: jsonEncode(create()),
                      ),
                    ],
                    finishReason: 'tool_calls',
                    model: model,
                  ),
                ],
              ),
        ),
        taskRepositoryProvider.overrideWithValue(tasks),
        taskImageStoreProvider.overrideWithValue(store),
        notificationSchedulerProvider.overrideWithValue(FakeScheduler()),
        // Same reference-checking boundary as production, backed by fake rows.
        // Never open SQLite or invoke platform photo APIs in these tests.
        taskPhotoReleaseProvider.overrideWithValue((paths) async {
          releaseAttempts.addAll(paths);
          final referenced = (await tasks.getTasks())
              .expand((task) => task.imagePaths)
              .toSet();
          for (final path in paths.toSet().difference(referenced)) {
            if (await store.isManaged(path)) {
              await File(path).delete();
              deleted.add(path);
            }
          }
        }),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await temp.delete(recursive: true);
  });

  test('real queue provider binds source, persists chosen draft and executes independent task copy', () async {
    final sessionId = chat.seedSession(title: '附图回归').id!;
    final queue = container.read(aiQueueControllerProvider);
    final entry = await queue.enqueue(
      sessionId: sessionId,
      text: '创建复习任务，附上选中的图片',
      imagePaths: sources.take(2).toList(),
    );
    Future<void> until(bool Function() predicate) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!predicate() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(
        predicate(),
        isTrue,
        reason: 'queue=${queue.entries.map((e) => '${e.status}: ${e.error}')}',
      );
    }

    await until(() => queue.confirmation != null || queue.blocked != null);
    expect(queue.blocked, isNull);
    expect(wireSystemPrompts.first, contains('只有本次照片'));
    expect(wireSystemPrompts.first, contains('photo_indices'));
    for (final path in [...sources, ...entry.imagePaths]) {
      expect(wireSystemPrompts.first, isNot(contains(path)));
    }
    final proposal = queue.confirmation!.proposals.single;
    final draft = AiTaskPhotoDraft.fromArgs(proposal.args)!;
    expect(draft.requestId, 'queue:${entry.id}');
    expect(draft.sourcePaths, entry.imagePaths);
    expect(draft.sourcePaths.toSet().intersection(sources.toSet()), isEmpty);
    expect(tasks.taskCount, 0);
    final selected = draft.withSelection(proposal.args, ['new:1']);
    await queue.updateConfirmationDraft(entry.id, 0, selected);
    final persisted = (await chatQueue.list()).single.checkpoint;
    final operation = (persisted['operations'] as List).single as Map;
    expect(
      AiTaskPhotoDraft.fromArgs(
        Map<String, dynamic>.from(operation['args'] as Map),
      )!.selectedIds,
      ['new:1'],
    );
    queue.confirm([queue.confirmation!.proposals.single.args]);
    await until(
      () =>
          queue.activeId == null &&
          queue.entries.single.status != ChatQueueStatus.waitingConfirmation,
    );
    expect(queue.entries.single.status, ChatQueueStatus.completed);
    final saved = (await tasks.getTasks()).single;
    expect(saved.imagePaths, hasLength(1));
    expect(entry.imagePaths.contains(saved.imagePaths.single), isFalse);
    await attachments.remove(entry.imagePaths);
    expect(await File(saved.imagePaths.single).readAsBytes(), png);
    expect(deleted, isEmpty);
  });

  test('single create defaults to current photos and survives chat source deletion', () async {
    final context = request();
    final args = await prepareTaskPhotoArgs(context, create());
    expect(tool.validate(args), isNull);
    final result = await execute(context, args);
    expect(result['status'], 'created');
    expect(result['photo_count'], 4);
    final saved = (await tasks.getTasks()).single;
    expect(saved.imagePaths, hasLength(4));
    expect(saved.imagePaths.toSet().intersection(sources.toSet()), isEmpty);
    expect(releaseAttempts, saved.imagePaths);
    expect(deleted, isEmpty);
    for (final source in sources) {
      await File(source).delete();
    }
    for (final path in saved.imagePaths) {
      expect(await File(path).readAsBytes(), png);
    }
  });

  for (final type in ['scheduled', 'daily', 'span']) {
    test('$type create imports photos through shared persistence', () async {
      final context = request(images: [sources.first]);
      final args = await prepareTaskPhotoArgs(
        context,
        create({'type': type, 'due_time': '09:00', 'start_date': '2029-12-30'}),
      );
      expect(tool.validate(args), isNull);
      expect((await execute(context, args))['status'], 'created');
      final saved = (await tasks.getTasks()).single;
      expect(saved.type.code, type);
      expect(saved.imagePaths, hasLength(1));
      expect(await File(saved.imagePaths.single).readAsBytes(), png);
    });
  }

  test('batch requires per-item choice and reused source produces independent copies', () async {
    final context = request();
    final first = await prepareTaskPhotoArgs(context, create(), createCount: 2);
    final second = await prepareTaskPhotoArgs(
      context,
      create({'title': '练习'}),
      createCount: 2,
    );
    expect(tool.validate(first), isNotNull);
    expect((await execute(context, first))['status'], 'error');
    expect(tasks.taskCount, 0);
    final a = AiTaskPhotoDraft.fromArgs(first)!.withSelection(first, ['new:1']);
    final b = AiTaskPhotoDraft.fromArgs(second)!
        .withSelection(second, ['new:1', 'new:3']);
    expect((await execute(context, a))['status'], 'created');
    expect((await execute(context, b))['status'], 'created');
    final saved = await tasks.getTasks();
    expect(saved[0].imagePaths, hasLength(1));
    expect(saved[1].imagePaths, hasLength(2));
    expect(saved[0].imagePaths.single, isNot(saved[1].imagePaths.first));
    await File(saved[0].imagePaths.single).delete();
    expect(await File(saved[1].imagePaths.first).readAsBytes(), png);
  });

  test(
    'text-only update with new input photos preserves original photos',
    () async {
      final old = await seedOld(2);
      final context = request();
      final args = await prepareTaskPhotoArgs(
        context,
        update({'description': '新描述'}),
      );
      expect(tool.validate(args), isNull);
      expect((await execute(context, args))['status'], 'updated');
      final saved = (await tasks.getTasks()).single;
      expect(saved.description, '新描述');
      expect(saved.imagePaths, old);
      expect(await copies(), hasLength(2));
      expect(releaseAttempts, isEmpty);
    },
  );

  test(
    'photo-only append accepts integral numeric task id and normalized action',
    () async {
      final old = await seedOld(1);
      final context = request();
      final args = await prepareTaskPhotoArgs(
        context,
        update({
          'action': ' UPDATE ',
          'task_id': 1.0,
          'photo_indices': [2],
        }),
      );
      expect(tool.validate(args), isNull);
      expect((await execute(context, args))['status'], 'updated');
      final saved = (await tasks.getTasks()).single;
      expect(saved.title, '旧任务');
      expect(saved.description, '旧描述');
      expect(saved.imagePaths.first, old.single);
      expect(saved.imagePaths, hasLength(2));
      expect(await File(saved.imagePaths.last).readAsBytes(), png);
    },
  );

  for (final mode in ['replace', 'remove', 'clear']) {
    test('photo-only $mode persists exact selection', () async {
      final old = await seedOld(2);
      final context = request();
      final args = await prepareTaskPhotoArgs(
        context,
        update({
          'photo_mode': mode,
          if (mode == 'replace') 'photo_indices': [3],
          if (mode == 'remove') 'remove_photo_indices': [1],
        }),
      );
      expect(tool.validate(args), isNull);
      expect((await execute(context, args))['status'], 'updated');
      final saved = (await tasks.getTasks()).single;
      expect(saved.description, '旧描述');
      if (mode == 'replace') {
        expect(saved.imagePaths, hasLength(1));
        expect(old.contains(saved.imagePaths.single), isFalse);
        expect(await File(saved.imagePaths.single).readAsBytes(), png);
      } else {
        expect(saved.imagePaths, mode == 'remove' ? [old.last] : isEmpty);
      }
    });
  }

  test(
    'more than four selected photos refuses execution without writes or copies',
    () async {
      final old = await seedOld(4);
      final context = request();
      final args = await prepareTaskPhotoArgs(
        context,
        update({
          'photo_mode': 'append',
          'photo_indices': [1],
        }),
      );
      expect(tool.validate(args), contains('最多'));
      expect((await execute(context, args))['status'], 'error');
      expect((await tasks.getTasks()).single.imagePaths, old);
      expect(await copies(), hasLength(4));
    },
  );

  for (final action in ['create', 'update']) {
    test(
      '$action missing later source rolls back copies and never saves without photos',
      () async {
        final old = action == 'update' ? await seedOld(1) : <String>[];
        final context = request();
        final fields = {
          'photo_indices': [1, 2],
          'photo_mode': 'append',
        };
        final args = await prepareTaskPhotoArgs(
          context,
          action == 'create' ? create(fields) : update(fields),
        );
        await File(sources[1]).delete();
        expect((await execute(context, args))['status'], 'error');
        expect(tasks.taskCount, action == 'create' ? 0 : 1);
        if (action == 'update') {
          expect((await tasks.getTasks()).single.imagePaths, old);
        }
        expect(deleted, hasLength(1));
        expect(await copies(), hasLength(old.length));
      },
    );

    test(
      '$action write then failed refresh retains referenced copies during release',
      () async {
        if (action == 'update') await seedOld(1);
        final context = request();
        final fields = {
          'photo_indices': [2],
          'photo_mode': 'append',
        };
        final args = await prepareTaskPhotoArgs(
          context,
          action == 'create' ? create(fields) : update(fields),
        );
        tasks.failReadAfterWrite = true;
        await expectLater(tool.execute(context, args), throwsStateError);
        final saved = (await tasks.getTasks()).single;
        expect(saved.imagePaths, hasLength(action == 'create' ? 1 : 2));
        expect(releaseAttempts, [saved.imagePaths.last]);
        expect(deleted, isEmpty);
        for (final path in saved.imagePaths) {
          expect(await File(path).readAsBytes(), png);
        }
      },
    );
  }
}
