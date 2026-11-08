import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/backup/backup_service.dart';
import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/db/db_schema.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/data/repositories/task_image_store.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'test_helpers.dart';

void main() {
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
  );
  late Directory root;
  late TestData data;
  late TaskImageStore store;
  late TaskRepository repo;
  Task task({String title = '照片任务', List<String> paths = const []}) => Task(
    title: title,
    type: TaskType.todo,
    dueDate: DateTime(2026, 11, 7),
    imagePaths: paths,
  );
  BackupService backup(TestData d, TaskImageStore s) => BackupService(
    db: d.db,
    timetable: d.timetable,
    tasks: d.tasks,
    settings: d.settings,
    imageStore: s,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('plai-photo-test-');
    data = await TestData.create();
    store = TaskImageStore(directory: Directory('${root.path}/images'));
    repo = TaskRepository(data.db, imageStore: store);
  });
  tearDown(() async {
    await data.db.close();
    await root.delete(recursive: true);
  });

  test('模型冻结照片，copyWith与DB/JSON保留顺序', () {
    final paths = ['a', 'b'];
    final value = task(paths: paths);
    paths.clear();
    expect(value.imagePaths, ['a', 'b']);
    expect(() => value.imagePaths.clear(), throwsUnsupportedError);
    expect(value.copyWith(title: '新标题').imagePaths, ['a', 'b']);
    expect(Task.fromDbMap(value.toDbMap()), value);
    expect(Task.fromJson(value.toJson()), value);
    expect(() => task(paths: ['1', '2', '3', '4', '5']), throwsFormatException);
  });

  test('CRUD只清理已无引用受管文件，不动相册原图', () async {
    final original = File('${root.path}/album.png');
    await original.writeAsBytes(png);
    final path = await store.importFile(original.path);
    final first = await repo.insertTask(task(paths: [path]));
    final second = await repo.insertTask(task(title: '共享', paths: [path]));
    await repo.deleteTask(first);
    expect(await File(path).exists(), isTrue);
    await repo.updateTask(
      (await repo.getTaskById(second))!.copyWith(imagePaths: []),
    );
    expect(await File(path).exists(), isFalse);
    expect(await original.exists(), isTrue);
    await store.removeIfUnreferenced(data.db, [original.path]);
    expect(await original.exists(), isTrue);
  });

  test('保存成功后的表单清理保留已引用新图', () async {
    final path = await store.importFile('', bytes: png);
    await repo.insertTask(task(paths: [path]));
    await store.removeIfUnreferenced(data.db, [path]);
    expect(await File(path).exists(), isTrue);
    final unused = await store.importFile('', bytes: png);
    await store.removeIfUnreferenced(data.db, [unused]);
    expect(await File(unused).exists(), isFalse);
  });

  test('拒绝损坏格式、超大文件与越界导出', () async {
    final oversized = File('${root.path}/huge.png');
    final handle = await oversized.open(mode: FileMode.write);
    await handle.truncate(TaskImageStore.maxImageBytes + 1);
    await handle.close();
    await expectLater(store.importFile(oversized.path), throwsFormatException);
    await expectLater(
      store.importFile('', bytes: List.filled(15, 0)),
      throwsFormatException,
    );
    final truncated = png.sublist(0, png.length - 12);
    await expectLater(
      store.importFile('', bytes: truncated),
      throwsFormatException,
    );
    final outside = File('${root.path}/private.png');
    await outside.writeAsBytes(png);
    await repo.insertTask(task(paths: [outside.path]));
    await expectLater(
      backup(data, store).exportToJson(),
      throwsA(isA<BackupFormatException>()),
    );
    expect(await outside.exists(), isTrue);
  });

  test('清理查询或解析异常保守保留文件', () async {
    final path = await store.importFile('', bytes: png);
    await (await data.db.database).insert(
      'task',
      task().toDbMap()..['image_paths'] = 'broken',
    );
    await store.removeIfUnreferenced(data.db, [path]);
    expect(await File(path).exists(), isTrue);
  });

  test('备份跨目录恢复真实字节；合并重复项不创建照片', () async {
    final path = await store.importFile('', bytes: png);
    await repo.insertTask(task(paths: [path]));
    final json = await backup(data, store).exportToJson();
    expect(json['version'], 3);
    expect(jsonEncode(json), isNot(contains(path)));
    expect(backup(data, store).preview(json).imageCount, 1);
    final target = await TestData.create();
    final targetStore = TaskImageStore(
      directory: Directory('${root.path}/target'),
    );
    try {
      await backup(
        target,
        targetStore,
      ).restore(json, strategy: RestoreStrategy.overwrite);
      final restored = (await target.tasks.getTasks()).single;
      expect(restored.imagePaths.single, isNot(path));
      expect(await File(restored.imagePaths.single).readAsBytes(), png);
      // V2 照片备份仍可预览及合并；V3 升版不能误拒旧照片引用。
      final legacyPhotoJson = {...json, 'version': 2};
      expect(
        backup(target, targetStore).preview(legacyPhotoJson).imageCount,
        1,
      );
      await backup(
        target,
        targetStore,
      ).restore(legacyPhotoJson, strategy: RestoreStrategy.merge);
      expect(await (await targetStore.directory).list().length, 1);
      expect(
        (await target.tasks.getTasks()).single.imagePaths,
        restored.imagePaths,
      );
    } finally {
      await target.db.close();
    }
  });

  test('损坏附件与不可信路径在写入前拒绝；旧v1无图正常恢复', () async {
    final path = await store.importFile('', bytes: png);
    await repo.insertTask(task(paths: [path]));
    final json = await backup(data, store).exportToJson();
    final images = json['data']['taskImages'] as Map;
    images.values.first['size'] = 5;
    await expectLater(
      backup(data, store).restore(json, strategy: RestoreStrategy.overwrite),
      throwsA(anything),
    );
    expect((await repo.getTasks()).single.imagePaths, [path]);
    expect(await File(path).exists(), isTrue);
    final legacy = {
      'format': 'plai-backup',
      'version': 1,
      'data': {
        'tasks': [task(title: '旧备份').toJson()..remove('imagePaths')],
      },
    };
    await backup(
      data,
      store,
    ).restore(legacy, strategy: RestoreStrategy.overwrite);
    expect((await repo.getTasks()).single.title, '旧备份');
    expect(await File(path).exists(), isFalse);
    legacy['data'] = {
      'tasks': [
        task(paths: ['../../secret']).toJson(),
      ],
    };
    await expectLater(
      backup(data, store).restore(legacy, strategy: RestoreStrategy.overwrite),
      throwsA(isA<BackupFormatException>()),
    );
  });

  test('恢复DB失败回滚新增照片并保留原图', () async {
    final path = await store.importFile('', bytes: png);
    await repo.insertTask(task(paths: [path]));
    final json = await backup(data, store).exportToJson();
    json['data']['periods'] = [
      {'index': 1, 'startTime': '08:00', 'endTime': '09:00'},
      {'index': 1, 'startTime': '10:00', 'endTime': '11:00'},
    ];
    await expectLater(
      backup(data, store).restore(json, strategy: RestoreStrategy.overwrite),
      throwsA(anything),
    );
    expect((await repo.getTasks()).single.imagePaths, [path]);
    expect(await (await store.directory).list().length, 1);
  });

  test('V6到V7迁移保留数据，已存在列可幂等升级', () async {
    for (final hasColumn in [false, true]) {
      final path = '${root.path}/migration-$hasColumn.db';
      final old = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 6,
          onCreate: (db, _) async {
            await db.execute(
              hasColumn
                  ? createTaskTable
                  : createTaskTable.replaceFirst(
                      "  image_paths TEXT NOT NULL DEFAULT '[]',\n",
                      '',
                    ),
            );
            await db.insert('task', task().toDbMap()..remove('image_paths'));
          },
        ),
      );
      await old.close();
      final migrated = AppDatabase(factory: databaseFactoryFfi, path: path);
      try {
        expect(
          (await TaskRepository(migrated).getTasks()).single.imagePaths,
          isEmpty,
        );
        expect(await (await migrated.database).getVersion(), dbVersion);
      } finally {
        await migrated.close();
      }
    }
  });
}
