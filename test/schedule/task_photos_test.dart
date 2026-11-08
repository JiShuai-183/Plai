import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/task_image_store.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:plai/features/schedule/schedule_providers.dart';
import 'package:plai/features/schedule/task_detail_page.dart';
import 'package:plai/features/schedule/task_form_page.dart';
import 'package:plai/features/schedule/task_list_tile.dart';
import 'package:plai/services/notifications/notification_providers.dart';
import 'package:plai/services/notifications/notification_scheduler.dart';
import 'package:plai/shared/task_photo_picker.dart';
import 'package:plai/shared/task_photo_prepare.dart';

class _Repository implements ITaskRepository {
  Task? saved;
  bool fail = false;
  bool failReadAfterSave = false;
  bool updateReturn0 = false;
  int writes = 0;
  int deletes = 0;
  Completer<void>? writing;

  @override
  Future<int> insertTask(Task task) async {
    writes++;
    await writing?.future;
    if (fail) throw StateError('save failed');
    saved = task.copyWith(id: task.id ?? 1);
    return saved!.id!;
  }

  @override
  Future<int> updateTask(Task task) async {
    if (updateReturn0) {
      writes++;
      return 0;
    }
    return insertTask(task);
  }

  @override
  Future<Task?> getTaskById(int id) async {
    if (failReadAfterSave && writes > 0) throw StateError('read failed');
    return saved;
  }

  @override
  Future<int> deleteTask(int id) async {
    deletes++;
    saved = null;
    return 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Scheduler extends NotificationScheduler {
  _Scheduler()
    : super(
        TimetableRepository(AppDatabase.instance),
        TaskRepository(AppDatabase.instance),
        SettingsRepository(AppDatabase.instance),
      );
  @override
  Future<void> scheduleTaskReminder(Task task) async {}
  @override
  Future<void> cancelAllRemindersFor({int? taskId, int? courseId}) async {}
}

class _Store extends TaskImageStore {
  final imported = <String>[];
  @override
  Future<String> importFile(
    String sourcePath, {
    List<int>? bytes,
    String? extension,
  }) async {
    final path = '/task_images/${imported.length}.png';
    imported.add(path);
    return path;
  }
}

class _Harness {
  final repo = _Repository();
  final store = _Store();
  final released = <String>[];
  final remaining = <int>[];
  List<String> picks = ['/photo.png'];
  Completer<List<String>>? picking;
  bool failOptions = false;

  Widget app({Task? task, Widget? home}) => ProviderScope(
    overrides: [
      taskRepositoryProvider.overrideWithValue(repo),
      taskImageStoreProvider.overrideWithValue(store),
      taskPhotoReleaseProvider.overrideWithValue((paths) async {
        // Model the reference check, including write-success/read-failure.
        released.addAll(
          paths.where((p) => !(repo.saved?.imagePaths.contains(p) ?? false)),
        );
      }),
      notificationSchedulerProvider.overrideWithValue(_Scheduler()),
      courseOptionsProvider.overrideWith((ref) async {
        if (failOptions) throw StateError('course options unavailable');
        return const <(int, String)>[];
      }),
      taskPhotoPreparerProvider.overrideWithValue((path) async => null),
      taskPhotoPickerProvider.overrideWithValue((
        context, {
        required remaining,
      }) async {
        this.remaining.add(remaining);
        return picking == null ? picks : picking!.future;
      }),
    ],
    child: MaterialApp(
      home:
          home ??
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => TaskFormPage(task: task),
                  ),
                ),
                child: const Text('打开表单'),
              ),
            ),
          ),
    ),
  );

  Future<void> open(WidgetTester tester, {Task? task}) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    repo.saved = task;
    await tester.pumpWidget(app(task: task));
    await tester.tap(find.text('打开表单'));
    await tester.pumpAndSettle();
  }

  Future<void> add(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('task_photo_add')));
    await tester.pumpAndSettle();
  }
}

Task _task({TaskType type = TaskType.todo, List<String> images = const []}) =>
    Task(
      id: 1,
      title: '复习',
      type: type,
      dueDate: DateTime(2030, 1, 5),
      startDate: type == TaskType.daily || type == TaskType.span
          ? DateTime(2030, 1, 1)
          : null,
      dueTime: type == TaskType.scheduled ? '08:00' : null,
      imagePaths: images,
    );

Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

void main() {
  for (final type in TaskType.values) {
    testWidgets(
      '${type.code}: image-only description saves and retained images survive',
      (tester) async {
        final h = _Harness();
        await h.open(tester, task: _task(type: type));
        await h.add(tester);
        expect(find.byKey(const ValueKey('task_photo_0')), findsOneWidget);
        await tester.tap(find.text('保存修改'));
        await tester.pumpAndSettle();
        expect(h.repo.saved!.description, isEmpty);
        expect(h.repo.saved!.imagePaths, h.store.imported);
        expect(h.repo.saved!.type, type);
        expect(h.released, isEmpty);
        expect(find.byType(TaskFormPage), findsNothing);
      },
    );
  }

  testWidgets(
    'untouched form defaults do not prompt; changing priority prompts',
    (tester) async {
      final h = _Harness();
      await h.open(tester, task: _task(type: TaskType.scheduled));
      await _back(tester);
      expect(find.text('保存更改？'), findsNothing);
      expect(find.byType(TaskFormPage), findsNothing);
      await tester.tap(find.text('打开表单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重要'));
      await tester.pump();
      await _back(tester);
      expect(find.text('保存更改？'), findsOneWidget);
    },
  );

  testWidgets(
    'picker receives remaining capacity and form defensively limits four',
    (tester) async {
      final h = _Harness()..picks = List.generate(8, (i) => '/photo$i.png');
      await h.open(tester, task: _task(images: ['/old.png']));
      await h.add(tester);
      expect(h.remaining, [3]);
      expect(h.store.imported.length, 3);
      final button = tester.widget<IconButton>(
        find.byKey(const Key('task_photo_add')),
      );
      expect(button.onPressed, isNull);
    },
  );

  testWidgets(
    'discard releases newly imported images and preserves original removed images',
    (tester) async {
      final h = _Harness();
      await h.open(tester, task: _task(images: ['/old.png']));
      final photo = tester.getRect(find.byKey(const ValueKey('task_photo_0')));
      final remove = tester.getRect(
        find.byKey(const ValueKey('task_photo_remove_0')),
      );
      expect(remove.center.dx, closeTo(photo.right, 0.01));
      expect(remove.center.dy, closeTo(photo.top, 0.01));
      final closeCenter = tester.getCenter(
        find.descendant(
          of: find.byKey(const ValueKey('task_photo_remove_0')),
          matching: find.byIcon(Icons.close),
        ),
      );
      expect((closeCenter - remove.center).distance, lessThan(0.01));
      // The part above the picture must remain visible and tappable.
      await tester.tapAt(remove.center + const Offset(0, -8));
      await tester.pumpAndSettle();
      expect(h.released, isEmpty);
      await h.add(tester);
      await _back(tester);
      await tester.tap(find.text('放弃更改'));
      await tester.pumpAndSettle();
      expect(h.released, h.store.imported);
      expect(h.repo.saved!.imagePaths, ['/old.png']);
      expect(h.repo.writes, 0);
    },
  );

  testWidgets(
    'remove new image releases it; editing and saving preserves remaining photos',
    (tester) async {
      final h = _Harness();
      await h.open(tester, task: _task(images: ['/old.png']));
      await h.add(tester);
      await tester.tap(find.byKey(const ValueKey('task_photo_remove_1')));
      await tester.pumpAndSettle();
      expect(h.released, h.store.imported);
      await h.add(tester);
      await tester.tap(find.byKey(const ValueKey('task_photo_remove_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();
      expect(h.repo.saved!.imagePaths, [h.store.imported.last]);
      expect(h.released, [h.store.imported.first]);
    },
  );

  testWidgets(
    'save-and-exit validation failure keeps form and imported photos',
    (tester) async {
      final h = _Harness();
      await h.open(tester);
      await h.add(tester);
      await _back(tester);
      await tester.tap(find.text('保存并退出'));
      await tester.pumpAndSettle();
      expect(find.text('请输入标题'), findsOneWidget);
      expect(find.byType(TaskFormPage), findsOneWidget);
      expect(h.released, isEmpty);
      expect(h.repo.writes, 0);
    },
  );

  for (final saveOnLeave in [false, true]) {
    testWidgets(
      'deleted task update (${saveOnLeave ? 'save on leave' : 'save button'}) keeps photo draft until discard',
      (tester) async {
        final h = _Harness();
        await h.open(tester, task: _task());
        await h.add(tester);
        h.repo.saved =
            null; // Another writer deleted the task while form was open.
        h.repo.updateReturn0 = true;
        if (saveOnLeave) {
          await _back(tester);
          await tester.tap(find.text('保存并退出'));
        } else {
          await tester.tap(find.text('保存修改'));
        }
        await tester.pumpAndSettle();
        expect(find.byType(TaskFormPage), findsOneWidget);
        expect(find.byKey(const ValueKey('task_photo_0')), findsOneWidget);
        expect(h.repo.saved, isNull);
        expect(h.repo.writes, 1);
        expect(h.released, isEmpty);
        await _back(tester);
        await tester.tap(find.text('放弃更改'));
        await tester.pumpAndSettle();
        expect(find.byType(TaskFormPage), findsNothing);
        expect(h.released, h.store.imported);
      },
    );
  }

  testWidgets(
    'course options refresh error keeps draft when save-on-leave has no form',
    (tester) async {
      final h = _Harness();
      await h.open(tester, task: _task());
      await h.add(tester);
      await tester.enterText(find.byType(TextFormField).first, '未保存标题');
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(TaskFormPage)),
      );
      h.failOptions = true;
      container.invalidate(courseOptionsProvider);
      await tester.pumpAndSettle();
      expect(find.text('课程数据加载失败'), findsOneWidget);
      expect(find.byType(Form), findsNothing);
      await _back(tester);
      await tester.tap(find.text('保存并退出'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(find.byType(TaskFormPage), findsOneWidget);
      expect(find.text('表单尚未就绪，请稍后重试'), findsOneWidget);
      expect(h.repo.writes, 0);
      expect(h.released, isEmpty);
      await _back(tester);
      await tester.tap(find.text('放弃更改'));
      await tester.pumpAndSettle();
      expect(h.released, h.store.imported);
      expect(find.byType(TaskFormPage), findsNothing);
    },
  );

  testWidgets('failed save-and-exit keeps images, retry succeeds', (
    tester,
  ) async {
    final h = _Harness()..repo.fail = true;
    await h.open(tester, task: _task());
    await h.add(tester);
    await _back(tester);
    await tester.tap(find.text('保存并退出'));
    await tester.pumpAndSettle();
    expect(find.byType(TaskFormPage), findsOneWidget);
    expect(h.released, isEmpty);
    h.repo.fail = false;
    await _back(tester);
    await tester.tap(find.text('保存并退出'));
    await tester.pumpAndSettle();
    expect(find.byType(TaskFormPage), findsNothing);
    expect(h.repo.saved!.imagePaths, h.store.imported);
    expect(h.released, isEmpty);
  });

  testWidgets(
    'cancel via barrier/repeated back keeps edits; discard eventually releases',
    (tester) async {
      final h = _Harness();
      await h.open(tester, task: _task());
      await h.add(tester);
      await _back(tester);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(TaskFormPage), findsOneWidget);
      await _back(tester);
      await _back(tester); // closes the existing dialog, never creates another.
      expect(find.text('保存更改？'), findsNothing);
      expect(h.released, isEmpty);
      await _back(tester);
      await tester.tap(find.text('放弃更改'));
      await tester.pumpAndSettle();
      expect(h.released, h.store.imported);
    },
  );

  testWidgets('double picker/save and back while saving cannot race', (
    tester,
  ) async {
    final h = _Harness()..picking = Completer<List<String>>();
    await h.open(tester, task: _task());
    await tester.tap(find.byKey(const Key('task_photo_add')));
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('task_photo_add')),
      warnIfMissed: false,
    );
    expect(h.remaining, [4]);
    h.picking!.complete(['/photo.png']);
    await tester.pumpAndSettle();
    h.repo.writing = Completer<void>();
    await tester.tap(find.text('保存修改'));
    await tester.pump();
    await tester.tap(find.text('保存修改'), warnIfMissed: false);
    await _back(tester);
    expect(h.repo.writes, 1);
    expect(find.text('保存更改？'), findsNothing);
    h.repo.writing!.complete();
    await tester.pumpAndSettle();
    expect(h.released, isEmpty);
  });

  testWidgets(
    'external dispose releases drafts but protects already committed references',
    (tester) async {
      final h = _Harness();
      await h.open(tester, task: _task());
      await h.add(tester);
      h.repo.failReadAfterSave = true;
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();
      expect(find.byType(TaskFormPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(h.released, isEmpty);
      expect(h.repo.saved!.imagePaths, h.store.imported);
    },
  );

  testWidgets('external dispose releases unsaved draft images', (tester) async {
    final h = _Harness();
    await h.open(tester, task: _task());
    await h.add(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(h.released, h.store.imported);
  });

  testWidgets(
    'dispose during failed save defers cleanup until write completes',
    (tester) async {
      final h = _Harness();
      await h.open(tester, task: _task());
      await h.add(tester);
      h.repo.fail = true;
      h.repo.writing = Completer<void>();
      await tester.tap(find.text('保存修改'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(h.released, isEmpty);
      h.repo.writing!.complete();
      await tester.pumpAndSettle();
      expect(h.released, h.store.imported);
    },
  );

  testWidgets(
    'leave prompt dismisses keyboard and cancellation preserves text',
    (tester) async {
      final h = _Harness();
      await h.open(tester, task: _task());
      await tester.enterText(find.byType(TextFormField).first, '修改后的标题');
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      await _back(tester);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(find.text('保存更改？'), findsOneWidget);
      await _back(tester);
      expect(find.text('修改后的标题'), findsOneWidget);
    },
  );

  testWidgets('delete removes task and releases this form draft only', (
    tester,
  ) async {
    final h = _Harness();
    await h.open(tester, task: _task(images: ['/old.png']));
    await h.add(tester);
    await tester.tap(find.byTooltip('删除任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(h.repo.deletes, 1);
    expect(h.released, h.store.imported);
    expect(find.byType(TaskFormPage), findsNothing);
  });

  testWidgets('image-only detail displays description and opens large viewer', (
    tester,
  ) async {
    final h = _Harness();
    h.repo.saved = _task(images: ['/old.png']);
    await tester.pumpWidget(h.app(home: const TaskDetailPage(taskId: 1)));
    await tester.pumpAndSettle();
    expect(find.text('任务描述'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('task_detail_photo_0')));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('task tile includes accessible photo count', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskListTile(task: _task(images: ['/a.png', '/b.png'])),
        ),
      ),
    );
    expect(find.bySemanticsLabel(RegExp('2 张照片')), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets(
    'detail places long description in ordered card on narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1600);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final h = _Harness();
      final description = List.filled(8, '任务说明应当完整换行显示，不截断文字。').join();
      h.repo.saved = _task().copyWith(
        description: description,
        dailyRemindTime: '20:00',
      );
      await tester.pumpWidget(h.app(home: const TaskDetailPage(taskId: 1)));
      await tester.pumpAndSettle();
      expect(find.text(description), findsOneWidget);
      expect(find.text('任务描述'), findsOneWidget);
      expect(find.text('描述'), findsNothing);
      expect(
        find.ancestor(of: find.text(description), matching: find.byType(Card)),
        findsOneWidget,
      );
      final labels = ['截止', '任务描述', '提醒', '关联课程'];
      for (var i = 1; i < labels.length; i++) {
        expect(
          tester.getTopLeft(find.text(labels[i])).dy,
          greaterThan(tester.getTopLeft(find.text(labels[i - 1])).dy),
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'detail shows empty description and top delete keeps confirmation',
    (tester) async {
      final h = _Harness();
      h.repo.saved = _task();
      await tester.pumpWidget(
        h.app(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const TaskDetailPage(taskId: 1),
                  ),
                ),
                child: const Text('查看详情'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('查看详情'));
      await tester.pumpAndSettle();
      expect(find.text('暂无描述'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byTooltip('删除任务'),
          matching: find.byType(AppBar),
        ),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, '删除任务'), findsNothing);
      await tester.tap(find.byTooltip('删除任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(h.repo.deletes, 0);
      await tester.tap(find.byTooltip('删除任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(h.repo.deletes, 1);
      expect(find.byType(TaskDetailPage), findsNothing);
    },
  );

  for (final width in [320.0, 360.0, 411.0]) {
    testWidgets(
      'phone $width / large text / keyboard: four photos and save remain reachable',
      (tester) async {
        final h = _Harness()..picks = List.generate(4, (i) => '/photo$i.png');
        await h.open(tester, task: _task());
        tester.view.physicalSize = Size(width, 740);
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField).first, '手机任务');
        await tester.ensureVisible(find.byKey(const Key('task_photo_add')));
        await h.add(tester);
        expect(tester.testTextInput.isVisible, isFalse);
        expect(find.byKey(const ValueKey('task_photo_3')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          find.text('保存修改'),
          180,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(find.widgetWithText(FilledButton, '保存修改'));
        await tester.pumpAndSettle();
        expect(find.text('保存修改').hitTestable(), findsOneWidget);
        await tester.tap(find.text('保存修改'));
        await tester.pumpAndSettle();
        expect(h.repo.saved!.title, '手机任务');
        expect(h.repo.saved!.imagePaths.length, 4);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
