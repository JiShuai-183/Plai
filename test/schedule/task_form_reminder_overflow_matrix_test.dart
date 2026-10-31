// 诊断用矩阵测试：「提醒时刻」滚轮弹层在真实机型尺寸 / 字号 / 键盘遮挡下
// 是否溢出。此文件先生成证据（失败信息带具体尺寸与 overflow 像素），
// 修好后再把它保留为回归用例。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:plai/features/schedule/schedule_providers.dart';
import 'package:plai/features/schedule/task_form_page.dart';
import 'package:plai/services/notifications/class_reminder_planner.dart';
import 'package:plai/services/notifications/notification_providers.dart';
import 'package:plai/services/notifications/notification_scheduler.dart';
import 'package:plai/theme/theme.dart';

class _FakeTaskRepo implements ITaskRepository {
  final Map<int, Task> _byId = <int, Task>{};
  int _nextId = 1;

  @override
  Future<List<Task>> getTasks({
    TaskType? type,
    bool? completed,
    DateTime? from,
    DateTime? to,
  }) async =>
      _byId.values.toList();

  @override
  Future<Task?> getTaskById(int id) async => _byId[id];

  @override
  Future<int> insertTask(Task task) async {
    final int id = _nextId++;
    _byId[id] = task.copyWith(id: id);
    return id;
  }

  @override
  Future<int> updateTask(Task task) async => 1;

  @override
  Future<int> deleteTask(int id) async => 1;

  @override
  Future<int> setCompleted(int id, bool completed) async => 1;

  @override
  Future<void> markDailyCompleted(int taskId, DateTime date) async {}

  @override
  Future<void> clearDailyCompleted(int taskId, DateTime date) async {}

  @override
  Future<bool> isDailyCompleted(int taskId, DateTime date) async => false;

  @override
  Future<List<DateTime>> dailyLogsFor(int taskId) async => const <DateTime>[];
}

class _FakeScheduler extends NotificationScheduler {
  _FakeScheduler()
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

DateTime _todayOnly() {
  final DateTime now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

Widget _wrap(_FakeTaskRepo repo) {
  return ProviderScope(
    overrides: [
      taskRepositoryProvider.overrideWithValue(repo),
      notificationSchedulerProvider.overrideWithValue(_FakeScheduler()),
      courseOptionsProvider.overrideWith((ref) async => const <(int, String)>[]),
    ],
    child: MaterialApp(
      theme: PlaiTheme.light(),
      home: TaskFormPage(initialDate: _todayOnly()),
    ),
  );
}

/// 单次探测：返回收集到的错误文本（空 = 无异常）。
Future<String> _probe(
  WidgetTester tester, {
  required String label,
  required Size size,
  required double textScale,
  required double keyboard,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final List<String> errors = <String>[];
  void collect() {
    final Object? e = tester.takeException();
    if (e != null) errors.add(e.toString().split('\n').first);
  }

  await tester.pumpWidget(_wrap(_FakeTaskRepo()));
  await tester.pumpAndSettle();
  collect();

  // 滚到底，确认整张表单（含提醒区）不溢出。
  final Finder listScrollable = find
      .descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.drag(listScrollable, const Offset(0, -3000));
  await tester.pumpAndSettle();
  collect();

  await tester.drag(listScrollable, const Offset(0, 3000));
  await tester.pumpAndSettle();

  // ListView 是懒加载的：目标可能还没构建，先滚动到可见再操作。
  Future<void> reveal(Finder finder) async {
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        finder,
        150,
        scrollable: listScrollable,
        maxScrolls: 80,
      );
    } else {
      await tester.ensureVisible(finder.first);
    }
    await tester.pumpAndSettle();
  }

  // 打开提醒开关（不重复 / 每天两种模式都过一遍）。
  await reveal(find.byType(SwitchListTile));
  await tester.tap(find.byType(SwitchListTile));
  await tester.pumpAndSettle();
  collect();

  for (final String mode in <String>['每天', '不重复']) {
    await reveal(find.text(mode));
    await tester.tap(find.text(mode));
    await tester.pumpAndSettle();
    collect();

    await reveal(find.text('提醒时刻'));
    await tester.tap(find.text('提醒时刻'));
    await tester.pumpAndSettle();
    collect();

    // 弹层里按钮必须真实可见且落在屏幕内。
    for (final String btn in <String>['确定', '取消']) {
      final Finder f = find.text(btn);
      if (f.evaluate().isNotEmpty && !f.hitTestable().evaluate().isNotEmpty) {
        errors.add('$mode 弹层「$btn」不可点击（被裁掉/挤出）');
      }
    }
    if (find.text('取消').evaluate().isNotEmpty) {
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      collect();
    }
  }

  if (errors.isEmpty) return '';
  return '[$label size=${size.width.toInt()}x${size.height.toInt()} '
      'scale=$textScale keyboard=${keyboard.toInt()}]\n  '
      '${errors.join('\n  ')}';
}

void main() {
  // 真实 Android 机型逻辑尺寸（dp）× 常见字号 × 键盘遮挡。
  const List<Size> sizes = <Size>[
    Size(320, 568), // iPhone SE 一代 / 极小屏
    Size(360, 640), // 旧款 16:9 中低端
    Size(360, 800), // 主流 18:9
    Size(393, 851), // Pixel 类
    Size(412, 915), // 主流 19.5:9
  ];
  const List<double> scales = <double>[1.0, 1.3, 1.5, 2.0];
  const List<double> keyboards = <double>[0, 300, 380];

  testWidgets('矩阵：表单与滚轮弹层在所有常见尺寸/字号/键盘下都不溢出',
      (WidgetTester tester) async {
    final List<String> failures = <String>[];
    for (final Size size in sizes) {
      for (final double scale in scales) {
        for (final double keyboard in keyboards) {
          // 键盘高度不可能超过屏幕。
          if (keyboard > size.height * 0.6) continue;
          final String r = await _probe(
            tester,
            label: 'matrix',
            size: size,
            textScale: scale,
            keyboard: keyboard,
          );
          if (r.isNotEmpty) failures.add(r);
          await tester.pumpWidget(const SizedBox());
        }
      }
    }
    expect(failures, isEmpty,
        reason: '共 ${failures.length} 处溢出/不可见：\n${failures.join('\n')}');
  });
}
