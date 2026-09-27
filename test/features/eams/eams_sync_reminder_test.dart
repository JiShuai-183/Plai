import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/semester.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/features/timetable/eams/eams_sync_reminder.dart';
import 'package:plai/features/timetable/timetable_providers.dart';
import 'package:plai/routes/app_routes.dart';

/// 内存设置仓库（可让写入抛异常，验证打点失败被静默吞掉）。
class _FakeSettings implements ISettingsRepository {
  final Map<String, String> values = <String, String>{};
  bool failWrites = false;

  @override
  Future<String?> getValue(String key) async => values[key];

  @override
  Future<void> setValue(String key, String value) async {
    if (failWrites) throw StateError('settings-down');
    values[key] = value;
  }

  @override
  Future<void> setAll(Map<String, String> entries) async {
    if (failWrites) throw StateError('settings-down');
    values.addAll(entries);
  }

  @override
  Future<Map<String, String>> getAll() async => Map<String, String>.of(values);

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }
}

/// 承载 `maybeRemind` 调用上下文的宿主页面。
class _ReminderHost extends StatelessWidget {
  const _ReminderHost();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('host')));
}

/// 「立即同步」跳转目标：回显路由参数，用于断言 `arguments == true`。
class _ArgsProbe extends StatelessWidget {
  const _ArgsProbe();

  @override
  Widget build(BuildContext context) {
    final Object? args = ModalRoute.of(context)?.settings.arguments;
    return Scaffold(body: Center(child: Text('args:$args')));
  }
}

Semester _semester(int? id) => Semester(
  id: id,
  name: '2026 秋',
  startDate: DateTime(2026, 9, 1),
  totalWeeks: 16,
);

String _ms(DateTime t) => t.millisecondsSinceEpoch.toString();

/// 装配一屏宿主 App，注入假 settings / 注入时钟 / 假学期。
Future<GlobalKey<NavigatorState>> _pumpReminder(
  WidgetTester tester, {
  required _FakeSettings settings,
  required DateTime Function() now,
  Semester? semester,
}) async {
  final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        settingsRepositoryProvider.overrideWithValue(settings),
        currentSemesterProvider.overrideWith((Ref ref) async => semester),
        eamsSyncReminderProvider.overrideWith(
          (Ref ref) => EamsSyncReminder(settings: settings, ref: ref, now: now),
        ),
      ],
      child: MaterialApp(
        navigatorKey: navKey,
        home: const _ReminderHost(),
        routes: <String, WidgetBuilder>{
          AppRoutes.eamsImport: (_) => const _ArgsProbe(),
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return navKey;
}

/// 取宿主上下文与其 EamsSyncReminder 实例（`last` 取最后压栈的那一个）。
({EamsSyncReminder reminder, BuildContext context}) _host(
  WidgetTester tester, {
  bool last = false,
}) {
  final Finder finder = find.byType(_ReminderHost);
  final Element el = tester.element(last ? finder.last : finder.first);
  final EamsSyncReminder reminder = ProviderScope.containerOf(
    el,
    listen: false,
  ).read(eamsSyncReminderProvider);
  return (reminder: reminder, context: el);
}

void main() {
  final DateTime t0 = DateTime(2026, 9, 26, 10);

  group('真值表', () {
    testWidgets('T1 开关关（enabled=0）即使该弹也不弹', (WidgetTester tester) async {
      final _FakeSettings settings = _FakeSettings()
        ..values[EamsSyncKeys.enabled] = '0';
      await _pumpReminder(
        tester,
        settings: settings,
        now: () => t0,
        semester: _semester(7),
      );
      final r = _host(tester);
      await r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();
      expect(find.text('课表同步提醒'), findsNothing);
    });

    testWidgets('T1b 开关键缺省视作开 → 该弹就弹', (WidgetTester tester) async {
      final _FakeSettings settings = _FakeSettings()
        ..values[EamsSyncKeys.lastSemesterId] = '7'
        ..values[EamsSyncKeys.lastAt] = _ms(t0.subtract(const Duration(days: 7)));
      await _pumpReminder(
        tester,
        settings: settings,
        now: () => t0,
        semester: _semester(7),
      );
      final r = _host(tester);
      final Future<void> f = r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();
      expect(find.text('课表同步提醒'), findsOneWidget);
      await tester.tap(find.text('下次提醒'));
      await tester.pumpAndSettle();
      await f;
    });

    testWidgets('T1c 开关键为空串（异常值）→ 视作开，该弹就弹', (WidgetTester tester) async {
      // 统一口径：只有 '0' 表示关；缺失 / 空串 / 其它值一律视作开。
      final _FakeSettings settings = _FakeSettings()
        ..values[EamsSyncKeys.enabled] = ''
        ..values[EamsSyncKeys.lastSemesterId] = '7'
        ..values[EamsSyncKeys.lastAt] = _ms(t0.subtract(const Duration(days: 7)));
      await _pumpReminder(
        tester,
        settings: settings,
        now: () => t0,
        semester: _semester(7),
      );
      final r = _host(tester);
      final Future<void> f = r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();
      expect(find.text('课表同步提醒'), findsOneWidget);
      await tester.tap(find.text('下次提醒'));
      await tester.pumpAndSettle();
      await f;
    });

    testWidgets('T1d 开关键为 true（异常值）→ 视作开，该弹就弹', (WidgetTester tester) async {
      final _FakeSettings settings = _FakeSettings()
        ..values[EamsSyncKeys.enabled] = 'true'
        ..values[EamsSyncKeys.lastSemesterId] = '7'
        ..values[EamsSyncKeys.lastAt] = _ms(t0.subtract(const Duration(days: 7)));
      await _pumpReminder(
        tester,
        settings: settings,
        now: () => t0,
        semester: _semester(7),
      );
      final r = _host(tester);
      final Future<void> f = r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();
      expect(find.text('课表同步提醒'), findsOneWidget);
      await tester.tap(find.text('下次提醒'));
      await tester.pumpAndSettle();
      await f;
    });

    testWidgets('T7 无当前学期 → 不弹', (WidgetTester tester) async {
      final _FakeSettings settings = _FakeSettings();
      await _pumpReminder(tester, settings: settings, now: () => t0, semester: null);
      final r = _host(tester);
      await r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();
      expect(find.text('课表同步提醒'), findsNothing);
    });

    testWidgets('T2 本学期从未同步（lastSemesterId 缺失）→ 弹', (WidgetTester tester) async {
      final _FakeSettings settings = _FakeSettings();
      await _pumpReminder(
        tester,
        settings: settings,
        now: () => t0,
        semester: _semester(7),
      );
      final r = _host(tester);
      final Future<void> f = r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();
      expect(find.text('课表同步提醒'), findsOneWidget);
      await tester.tap(find.text('下次提醒'));
      await tester.pumpAndSettle();
      await f;
    });

    testWidgets('T2b 换了学期（lastSemesterId 不等）→ 弹', (WidgetTester tester) async {
      final _FakeSettings settings = _FakeSettings()
        ..values[EamsSyncKeys.lastSemesterId] = '3'
        ..values[EamsSyncKeys.lastAt] = _ms(t0); // 刚刚同步过，但那是别的学期
      await _pumpReminder(
        tester,
        settings: settings,
        now: () => t0,
        semester: _semester(7),
      );
      final r = _host(tester);
      final Future<void> f = r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();
      expect(find.text('课表同步提醒'), findsOneWidget);
      await tester.tap(find.text('下次提醒'));
      await tester.pumpAndSettle();
      await f;
    });

    testWidgets('T3 lastAt = 6 天 23 小时 → 不弹', (WidgetTester tester) async {
      final _FakeSettings settings = _FakeSettings()
        ..values[EamsSyncKeys.lastSemesterId] = '7'
        ..values[EamsSyncKeys.lastAt] = _ms(
          t0.subtract(const Duration(days: 6, hours: 23)),
        );
      await _pumpReminder(
        tester,
        settings: settings,
        now: () => t0,
        semester: _semester(7),
      );
      final r = _host(tester);
      await r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();
      expect(find.text('课表同步提醒'), findsNothing);
    });

    testWidgets('T3b lastAt = 整 7 天 → 弹', (WidgetTester tester) async {
      final _FakeSettings settings = _FakeSettings()
        ..values[EamsSyncKeys.lastSemesterId] = '7'
        ..values[EamsSyncKeys.lastAt] = _ms(
          t0.subtract(const Duration(days: 7)),
        );
      await _pumpReminder(
        tester,
        settings: settings,
        now: () => t0,
        semester: _semester(7),
      );
      final r = _host(tester);
      final Future<void> f = r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();
      expect(find.text('课表同步提醒'), findsOneWidget);
      await tester.tap(find.text('下次提醒'));
      await tester.pumpAndSettle();
      await f;
    });

    testWidgets('T3 nextRemindAt 未到 → 不弹（节流）', (WidgetTester tester) async {
      final _FakeSettings settings = _FakeSettings()
        ..values[EamsSyncKeys.nextRemindAt] = _ms(
          t0.add(const Duration(hours: 1)),
        );
      await _pumpReminder(
        tester,
        settings: settings,
        now: () => t0,
        semester: _semester(7),
      );
      final r = _host(tester);
      await r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();
      expect(find.text('课表同步提醒'), findsNothing);
    });

    testWidgets('T9 nextRemindAt 到点（等于 now）→ 弹', (WidgetTester tester) async {
      final _FakeSettings settings = _FakeSettings()
        ..values[EamsSyncKeys.lastSemesterId] = '7'
        ..values[EamsSyncKeys.lastAt] = _ms(
          t0.subtract(const Duration(days: 7)),
        )
        ..values[EamsSyncKeys.nextRemindAt] = _ms(t0);
      await _pumpReminder(
        tester,
        settings: settings,
        now: () => t0,
        semester: _semester(7),
      );
      final r = _host(tester);
      final Future<void> f = r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();
      expect(find.text('课表同步提醒'), findsOneWidget);
      await tester.tap(find.text('下次提醒'));
      await tester.pumpAndSettle();
      await f;
    });
  });

  group('弹窗后重新计时', () {
    testWidgets('T4/T5 弹后立刻再判 → 不弹；提醒后同步 → 重新计时', (
      WidgetTester tester,
    ) async {
      final _FakeSettings settings = _FakeSettings();
      DateTime clock = t0;
      await _pumpReminder(
        tester,
        settings: settings,
        now: () => clock,
        semester: _semester(7),
      );
      final r = _host(tester);

      // 首次弹窗，点「下次提醒」→ 只写 nextRemindAt。
      final Future<void> f1 = r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();
      expect(find.text('课表同步提醒'), findsOneWidget);
      await tester.tap(find.text('下次提醒'));
      await tester.pumpAndSettle();
      await f1;
      expect(settings.values[EamsSyncKeys.nextRemindAt], _ms(t0.add(const Duration(days: 7))));

      // 立刻再判 → 被节流，不弹。
      await r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();
      expect(find.text('课表同步提醒'), findsNothing);

      // 1 天后真的同步了一次 → lastAt 重置。
      clock = t0.add(const Duration(days: 1));
      await r.reminder.recordSync(7);
      expect(settings.values[EamsSyncKeys.lastSemesterId], '7');
      expect(settings.values[EamsSyncKeys.lastAt], _ms(clock));

      // 刚同步完 → 不弹。
      await r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();
      expect(find.text('课表同步提醒'), findsNothing);

      // 同步满 7 天（且 nextRemindAt 已过）→ 再弹。
      clock = t0.add(const Duration(days: 8));
      final Future<void> f2 = r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();
      expect(find.text('课表同步提醒'), findsOneWidget);
      await tester.tap(find.text('下次提醒'));
      await tester.pumpAndSettle();
      await f2;
    });
  });

  group('弹窗规格', () {
    testWidgets('标题 / 正文精确匹配、两个按钮、外部与返回键都关不掉', (
      WidgetTester tester,
    ) async {
      final _FakeSettings settings = _FakeSettings();
      await _pumpReminder(
        tester,
        settings: settings,
        now: () => t0,
        semester: _semester(7),
      );
      final r = _host(tester);
      final Future<void> f = r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();

      expect(find.text('课表同步提醒'), findsOneWidget);
      expect(find.text('已经 7 天没有同步教务处课表了，建议同步一下课表'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '下次提醒'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '立即同步'), findsOneWidget);

      // barrierDismissible == false：不存在可点关闭的遮罩。
      expect(
        tester
            .widgetList<ModalBarrier>(find.byType(ModalBarrier))
            .every((ModalBarrier b) => !b.dismissible),
        isTrue,
      );

      // 点外部不关。
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('课表同步提醒'), findsOneWidget);

      // 返回键不关。
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('课表同步提醒'), findsOneWidget);

      await tester.tap(find.text('下次提醒'));
      await tester.pumpAndSettle();
      await f;
    });

    testWidgets('点「下次提醒」→ 写 nextRemindAt 且不跳转', (WidgetTester tester) async {
      final _FakeSettings settings = _FakeSettings();
      await _pumpReminder(
        tester,
        settings: settings,
        now: () => t0,
        semester: _semester(7),
      );
      final r = _host(tester);
      final Future<void> f = r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();
      await tester.tap(find.text('下次提醒'));
      await tester.pumpAndSettle();
      await f;

      expect(
        settings.values[EamsSyncKeys.nextRemindAt],
        _ms(t0.add(const Duration(days: 7))),
      );
      expect(find.byType(_ArgsProbe), findsNothing);
    });

    testWidgets('点「立即同步」→ 先写 nextRemindAt，再 pushNamed(arguments: true)', (
      WidgetTester tester,
    ) async {
      final _FakeSettings settings = _FakeSettings();
      await _pumpReminder(
        tester,
        settings: settings,
        now: () => t0,
        semester: _semester(7),
      );
      final r = _host(tester);
      final Future<void> f = r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();
      await tester.tap(find.text('立即同步'));
      await tester.pumpAndSettle();
      await f;

      expect(
        settings.values[EamsSyncKeys.nextRemindAt],
        _ms(t0.add(const Duration(days: 7))),
      );
      expect(find.text('args:true'), findsOneWidget);
    });
  });

  group('弹窗布局', () {
    testWidgets('按钮左右分置：下次提醒贴左、立即同步贴右，中间不相邻', (
      WidgetTester tester,
    ) async {
      final _FakeSettings settings = _FakeSettings();
      await _pumpReminder(
        tester,
        settings: settings,
        now: () => t0,
        semester: _semester(7),
      );
      final r = _host(tester);
      final Future<void> f = r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();

      final Rect later = tester.getRect(
        find.widgetWithText(TextButton, '下次提醒'),
      );
      final Rect syncNow = tester.getRect(
        find.widgetWithText(FilledButton, '立即同步'),
      );
      final Rect bar = tester.getRect(find.byType(OverflowBar));
      final Rect body = tester.getRect(
        find.text('已经 7 天没有同步教务处课表了，建议同步一下课表'),
      );

      // (a) 顺序未变：先「下次提醒」后「立即同步」。
      expect(later.left, lessThan(syncNow.left));

      // (b) 两按钮不相邻：水平间隙显著大于 0（比任一按钮还宽）。
      final double gap = syncNow.left - later.right;
      expect(gap, greaterThan(0));
      expect(gap, greaterThan(later.width));
      expect(gap, greaterThan(syncNow.width));

      // (c) 左右分置：分别贴住动作条两端（内容区左右缘），而非整体偏一侧。
      expect(later.left - bar.left, lessThan(1.0));
      expect(bar.right - syncNow.right, lessThan(1.0));
      expect((later.left - body.left).abs(), lessThan(1.0));
      // 动作条横跨内容区宽度，两按钮之间确有空档。
      expect(bar.width, greaterThan(later.width + syncNow.width));

      await tester.tap(find.text('下次提醒'));
      await tester.pumpAndSettle();
      await f;
    });

    testWidgets('窄屏放大字体：两按钮仍可达、不溢出', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final _FakeSettings settings = _FakeSettings();
      await _pumpReminder(
        tester,
        settings: settings,
        now: () => t0,
        semester: _semester(7),
      );
      final r = _host(tester);
      final Future<void> f = r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextButton, '下次提醒'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '立即同步'), findsOneWidget);

      await tester.ensureVisible(find.text('立即同步'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('立即同步'));
      await tester.pumpAndSettle();
      await f;
      // 窄屏大字体下主按钮动作不变：仍跳转且带 arguments: true。
      expect(find.text('args:true'), findsOneWidget);
    });
  });

  group('弹窗守卫', () {
    testWidgets('用户正在教务导入页（route.name == eamsImport）→ 不弹且不写', (
      WidgetTester tester,
    ) async {
      final _FakeSettings settings = _FakeSettings();
      final GlobalKey<NavigatorState> navKey = await _pumpReminder(
        tester,
        settings: settings,
        now: () => t0,
        semester: _semester(7),
      );
      navKey.currentState!.push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: AppRoutes.eamsImport),
          builder: (_) => const _ReminderHost(),
        ),
      );
      await tester.pumpAndSettle();

      final r = _host(tester, last: true);
      expect(ModalRoute.of(r.context)!.settings.name, AppRoutes.eamsImport);
      await r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();

      expect(find.text('课表同步提醒'), findsNothing);
      expect(settings.values.containsKey(EamsSyncKeys.nextRemindAt), isFalse);
    });

    testWidgets('已有对话框压栈（isCurrent != true）→ 不弹且不写', (WidgetTester tester) async {
      final _FakeSettings settings = _FakeSettings();
      await _pumpReminder(
        tester,
        settings: settings,
        now: () => t0,
        semester: _semester(7),
      );
      final r = _host(tester);

      unawaited(
        showDialog<void>(
          context: r.context,
          builder: (BuildContext ctx) => AlertDialog(
            title: const Text('别的弹窗'),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('关闭'),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('别的弹窗'), findsOneWidget);

      await r.reminder.maybeRemind(r.context);
      await tester.pumpAndSettle();

      expect(find.text('课表同步提醒'), findsNothing);
      expect(settings.values.containsKey(EamsSyncKeys.nextRemindAt), isFalse);

      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
    });
  });

  group('recordSync 打点', () {
    testWidgets('写入 lastAt 与 lastSemesterId', (WidgetTester tester) async {
      final _FakeSettings settings = _FakeSettings();
      await _pumpReminder(
        tester,
        settings: settings,
        now: () => t0,
        semester: _semester(7),
      );
      await _host(tester).reminder.recordSync(7);
      expect(settings.values[EamsSyncKeys.lastSemesterId], '7');
      expect(settings.values[EamsSyncKeys.lastAt], _ms(t0));
    });

    testWidgets('settings 抛异常 → 静默吞掉不抛出', (WidgetTester tester) async {
      final _FakeSettings settings = _FakeSettings()..failWrites = true;
      await _pumpReminder(
        tester,
        settings: settings,
        now: () => t0,
        semester: _semester(7),
      );
      await _host(tester).reminder.recordSync(7);
      expect(tester.takeException(), isNull);
    });
  });
}
