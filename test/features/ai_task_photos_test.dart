import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/data/repositories/task_image_store.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:plai/features/ai/ai_task_photos.dart';
import 'package:plai/features/ai/ai_tool_context.dart';
import 'package:plai/features/schedule/schedule_providers.dart';

class _Tasks implements ITaskRepository {
  Task? task;
  @override
  Future<Task?> getTaskById(int id) async => task?.id == id ? task : null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
  );
  late Directory directory;
  late TaskImageStore store;
  late _Tasks tasks;
  late ProviderContainer container;
  late List<String> sources;
  late List<String> releases;
  AiToolContext context({String id = 'queue:1', List<String>? images}) =>
      AiToolContext(
        read: container.read,
        invalidate: container.invalidate,
        requestId: id,
        imagePaths: images ?? sources,
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
  Task old(List<String> paths) => Task(
    id: 1,
    title: '旧任务',
    type: TaskType.todo,
    dueDate: DateTime(2030),
    imagePaths: paths,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('plai-ai-task-photo-');
    sources = [];
    for (var i = 0; i < 4; i++) {
      final source = File('${directory.path}/chat$i.png');
      await source.writeAsBytes(png);
      sources.add(source.path);
    }
    store = TaskImageStore(
      directory: Directory('${directory.path}/task_images'),
    );
    tasks = _Tasks();
    releases = [];
    container = ProviderContainer(
      overrides: [
        taskRepositoryProvider.overrideWithValue(tasks),
        taskImageStoreProvider.overrideWithValue(store),
        taskPhotoReleaseProvider.overrideWithValue((paths) async {
          for (final path in paths) {
            if (!(tasks.task?.imagePaths.contains(path) ?? false) &&
                await store.isManaged(path)) {
              releases.add(path);
              await File(path).delete();
            }
          }
        }),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'single create defaults to current photos; strips untrusted model draft',
    () async {
      final args = await prepareTaskPhotoArgs(
        context(),
        create({
          aiTaskPhotoDraftKey: {
            'sourcePaths': ['/secret'],
          },
        }),
      );
      final draft = AiTaskPhotoDraft.fromArgs(args)!;
      expect(draft.sourcePaths, sources);
      expect(draft.selectedIds, ['new:0', 'new:1', 'new:2', 'new:3']);
      expect(draft.validationError, isNull);
      expect(() => draft.sourcePaths.clear(), throwsUnsupportedError);
      expect(AiTaskPhotoDraft.fromArgs(create()), isNull);
    },
  );
  test('update accepts integral numeric and legacy string ids', () async {
    tasks.task = old(['/old.png']);
    for (final id in <Object>[1, 1.0, ' 1 ']) {
      final args = await prepareTaskPhotoArgs(
        context(),
        update({'action': ' UPDATE ', 'task_id': id, 'title': '新标题'}),
      );
      expect(args['task_id'], isA<int>());
      expect(args['task_id'], 1);
      expect(AiTaskPhotoDraft.fromArgs(args)!.basePaths, ['/old.png']);
    }
  });
  test('update rejects fractional, nonfinite and nonpositive ids', () async {
    tasks.task = old([]);
    for (final id in <Object?>[
      1.5,
      0,
      -1,
      double.infinity,
      double.nan,
      '1.0',
      'bad',
      null,
    ]) {
      await expectLater(
        prepareTaskPhotoArgs(context(), update({'task_id': id})),
        throwsA(
          anyOf(isA<FormatException>(), isA<JsonUnsupportedObjectError>()),
        ),
      );
    }
  });
  test('batch omissions require explicit selection including intentional empty choice', () async {
    final args = await prepareTaskPhotoArgs(
      context(),
      create(),
      createCount: 2,
    );
    final draft = AiTaskPhotoDraft.fromArgs(args)!;
    expect(draft.needsSelection, isTrue);
    expect(draft.validationError, isNotNull);
    final changed = draft.withSelection(args, []);
    expect(AiTaskPhotoDraft.fromArgs(changed)!.validationError, isNull);
    expect(AiTaskPhotoDraft.fromArgs(args)!.needsSelection, isTrue);
    expect(
      (await materializeTaskPhotos(context(), changed)).imagePaths,
      isEmpty,
    );
  });
  test(
    'each task can suggest a distinct subset and reuse a source independently',
    () async {
      final first = await prepareTaskPhotoArgs(
        context(),
        create({
          'photo_indices': [2],
        }),
        createCount: 2,
      );
      final second = await prepareTaskPhotoArgs(
        context(),
        create({
          'photo_indices': [2, 4],
        }),
        createCount: 2,
      );
      final a = await materializeTaskPhotos(context(), first);
      final b = await materializeTaskPhotos(context(), second);
      expect(a.imagePaths, hasLength(1));
      expect(b.imagePaths, hasLength(2));
      expect(a.imagePaths.single, isNot(b.imagePaths.first));
      await releaseTaskPhotoCopies(context(), a.createdPaths);
      expect(await File(b.imagePaths.first).exists(), isTrue);
    },
  );
  test(
    'plain text update keeps original photos even with new input photos',
    () async {
      tasks.task = old(['/old.png']);
      final args = await prepareTaskPhotoArgs(
        context(),
        update({'title': '改标题'}),
      );
      final draft = AiTaskPhotoDraft.fromArgs(args)!;
      expect(draft.selectedIds, ['old:0']);
      expect(hasTaskPhotoChanges(args), isFalse);
      expect(
        (await materializeTaskPhotos(
          context(),
          args,
          existing: tasks.task,
        )).imagePaths,
        ['/old.png'],
      );
    },
  );
  test('append overflow remains visible until user trims; final choice preserves old plus new', () async {
    tasks.task = old(['/a', '/b', '/c', '/d']);
    final args = await prepareTaskPhotoArgs(
      context(),
      update({'photo_mode': 'append'}),
    );
    final draft = AiTaskPhotoDraft.fromArgs(args)!;
    expect(draft.selectedIds, hasLength(8));
    expect(draft.validationError, contains('最多'));
    final edited = draft.withSelection(args, ['old:0', 'new:2']);
    expect(validateTaskPhotoArgs(edited), isNull);
    expect(hasTaskPhotoChanges(edited), isTrue);
    final files = await materializeTaskPhotos(
      context(),
      edited,
      existing: tasks.task,
    );
    expect(files.imagePaths.first, '/a');
    expect(files.createdPaths, hasLength(1));
    expect(
      taskPhotoChangeSignature(args),
      isNot(taskPhotoChangeSignature(edited)),
    );
  });
  test(
    'replace, remove and clear are distinct and do not copy retained old paths',
    () async {
      tasks.task = old(['/a', '/b']);
      final replace = await prepareTaskPhotoArgs(
        context(),
        update({
          'photo_mode': 'replace',
          'photo_indices': [3],
        }),
      );
      expect(AiTaskPhotoDraft.fromArgs(replace)!.selectedIds, ['new:2']);
      final remove = await prepareTaskPhotoArgs(
        context(),
        update({
          'photo_mode': 'remove',
          'remove_photo_indices': [1],
        }),
      );
      expect(AiTaskPhotoDraft.fromArgs(remove)!.selectedIds, ['old:1']);
      expect(
        (await materializeTaskPhotos(
          context(),
          remove,
          existing: tasks.task,
        )).createdPaths,
        isEmpty,
      );
      final clear = await prepareTaskPhotoArgs(
        context(),
        update({'photo_mode': 'clear'}),
      );
      expect(AiTaskPhotoDraft.fromArgs(clear)!.selectedIds, isEmpty);
    },
  );
  test('invalid public indices, duplicates, null, paths and unknown mode reject before copying', () async {
    for (final values in <Object?>[
      [0],
      [5],
      [1, 1],
      ['/arbitrary/file'],
      null,
    ]) {
      expect(
        validateTaskPhotoArgs(create({'photo_indices': values})),
        isNotNull,
      );
    }
    expect(validateTaskPhotoArgs(create({'photo_mode': 'upload'})), isNotNull);
    await expectLater(
      prepareTaskPhotoArgs(
        context(images: [sources.first]),
        create({
          'photo_indices': [2],
        }),
      ),
      throwsFormatException,
    );
    expect(
      AiTaskPhotoDraft.fromArgs({aiTaskPhotoDraftKey: '/private'})!
          .validationError,
      isNotNull,
    );
  });
  test(
    'binding rejects foreign queue, changed source and changed original photos',
    () async {
      tasks.task = old(['/old']);
      final args = await prepareTaskPhotoArgs(
        context(),
        update({
          'photo_mode': 'append',
          'photo_indices': [1],
        }),
      );
      await expectLater(
        materializeTaskPhotos(context(id: 'other'), args, existing: tasks.task),
        throwsFormatException,
      );
      await expectLater(
        materializeTaskPhotos(
          context(images: sources.reversed.toList()),
          args,
          existing: tasks.task,
        ),
        throwsFormatException,
      );
      await expectLater(
        materializeTaskPhotos(context(), args, existing: old(['/different'])),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'recovery guidance',
            contains('请跳过本项并重新发送修改请求'),
          ),
        ),
      );
      expect(await store.directory.then((d) => d.exists()), isFalse);
    },
  );
  test(
    'corrupted private selected path cannot bypass source restriction',
    () async {
      final args = await prepareTaskPhotoArgs(
        context(),
        create({
          'photo_indices': [1],
        }),
      );
      (args[aiTaskPhotoDraftKey] as Map)['selected'] = ['/secret'];
      await expectLater(
        materializeTaskPhotos(context(), args),
        throwsFormatException,
      );
      expect(await store.directory.then((d) => d.exists()), isFalse);
    },
  );
  test(
    'partly copied sources are cleaned if a later file is missing',
    () async {
      final args = await prepareTaskPhotoArgs(
        context(),
        create({
          'photo_indices': [1, 2],
        }),
      );
      await File(sources[1]).delete();
      await expectLater(
        materializeTaskPhotos(context(), args),
        throwsA(isA<FileSystemException>()),
      );
      expect(releases, hasLength(1));
      expect(await (await store.directory).list().toList(), isEmpty);
      expect(await File(sources[0]).exists(), isTrue);
    },
  );
  test('deleting chat sources leaves saved task copies readable; cleanup protects referenced files', () async {
    final args = await prepareTaskPhotoArgs(
      context(),
      create({
        'photo_indices': [1],
      }),
    );
    final files = await materializeTaskPhotos(context(), args);
    tasks.task = old(files.imagePaths);
    await File(sources.first).delete();
    await releaseTaskPhotoCopies(context(), files.createdPaths);
    expect(await File(files.imagePaths.single).readAsBytes(), png);
    expect(releases, isEmpty);
  });
  test('legacy no-photo update preserves originals; unconfirmed photo create is refused', () async {
    tasks.task = old(['/a']);
    expect(
      (await materializeTaskPhotos(
        context(),
        update({'title': '标题'}),
        existing: tasks.task,
      )).imagePaths,
      ['/a'],
    );
    await expectLater(
      materializeTaskPhotos(context(), create()),
      throwsFormatException,
    );
    expect(
      (await materializeTaskPhotos(context(images: []), create())).imagePaths,
      isEmpty,
    );
  });
}
