import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/task_repository.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:plai/services/notifications/keep_alive_checker.dart';
import 'package:plai/services/notifications/keep_alive_guide_page.dart';
import 'package:plai/services/notifications/notification_providers.dart';
import 'package:plai/services/notifications/notification_scheduler.dart';

/// 假检测器：返回固定结果、记录 openSettings / writeManualConfirm 调用，
/// 手动的「我已完成」用内存 map 模拟持久化。
class _FakeChecker extends KeepAliveChecker {
  _FakeChecker(this._items, {Map<String, bool>? seedConfirms})
      : confirms = <String, bool>{...?seedConfirms};

  final List<KeepAliveCheckItem> _items;
  final List<String> opened = <String>[];
  final List<(String, bool)> confirmedWrites = <(String, bool)>[];
  final Map<String, bool> confirms;

  @override
  Future<String> getManufacturer() async => 'Xiaomi';

  @override
  Future<KeepAliveBrand?> readSelectedBrand() async => null;

  @override
  Future<void> writeSelectedBrand(KeepAliveBrand brand) async {}

  @override
  Future<void> clearManualConfirms() async => confirms.clear();

  @override
  Future<bool> readManualConfirm(String itemId) async =>
      confirms[itemId] ?? false;

  @override
  Future<void> writeManualConfirm(String itemId, bool confirmed) async {
    confirmedWrites.add((itemId, confirmed));
    if (confirmed) {
      confirms[itemId] = true;
    } else {
      confirms.remove(itemId);
    }
  }

  @override
  Future<List<KeepAliveCheckItem>> collectChecks(KeepAliveBrand brand) async =>
      _items;

  @override
  Future<bool> openSettings(String target) async {
    opened.add(target);
    return true;
  }
}

/// 假调度器：不落库、不触插件（页面 initState 会 markKeepAliveGuideShown）。
class _FakeScheduler extends NotificationScheduler {
  _FakeScheduler()
      : super(
          TimetableRepository(AppDatabase.instance),
          TaskRepository(AppDatabase.instance),
          SettingsRepository(AppDatabase.instance),
        );

  @override
  Future<void> markKeepAliveGuideShown() async {}

  @override
  Future<void> scheduleTestReminder() async {}
}

KeepAliveCheckItem item(
  String id,
  String title,
  KeepAliveCheckState state, {
  String settingsTarget = 'appDetails',
  bool manualConfirmable = false,
}) =>
    KeepAliveCheckItem(
      id: id,
      title: title,
      detail: '$title 的后果说明',
      state: state,
      settingsTarget: settingsTarget,
      manualConfirmable: manualConfirmable,
    );

Widget _harness(_FakeChecker checker) => ProviderScope(
      overrides: <Override>[
        keepAliveCheckerProvider.overrideWithValue(checker),
        notificationSchedulerProvider.overrideWithValue(_FakeScheduler()),
      ],
      child: const MaterialApp(home: KeepAliveGuidePage()),
    );

/// 拉高视口，让检测结果与测试提醒区一次性构建，避免懒加载漏查。
void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<_FakeChecker> _pumpDetected(
  WidgetTester tester,
  List<KeepAliveCheckItem> items,
) async {
  final checker = _FakeChecker(items);
  await tester.pumpWidget(_harness(checker));
  await tester.pumpAndSettle();
  await tester.tap(find.text('检测当前设置'));
  await tester.pumpAndSettle();
  return checker;
}

void main() {
  testWidgets('三种渲染：✓已完成 / 点击设置 / 我已完成勾选框',
      (WidgetTester tester) async {
    _useTallSurface(tester);
    await _pumpDetected(tester, <KeepAliveCheckItem>[
      item('auto_start', '允许自启动', KeepAliveCheckState.unknown,
          settingsTarget: 'autostart', manualConfirmable: true),
      item('battery_optimization', '忽略电池优化', KeepAliveCheckState.notOk,
          settingsTarget: 'battery'),
      item('notification', '允许通知', KeepAliveCheckState.ok),
    ]);

    // ok → ✓ + 已完成。
    expect(find.text('已完成'), findsOneWidget);
    // notOk + unknown → 各一个「点击设置」。
    expect(find.text('点击设置'), findsNWidgets(2));
    expect(find.text('未完成'), findsOneWidget);
    expect(find.text('待确认'), findsOneWidget);
    // unknown + manualConfirmable → 「我已完成」勾选框。
    expect(find.text('我已完成'), findsOneWidget);
  });

  testWidgets('点击「点击设置」确实调到 openSettings（对应 target）',
      (WidgetTester tester) async {
    _useTallSurface(tester);
    final checker = await _pumpDetected(tester, <KeepAliveCheckItem>[
      item('auto_start', '允许自启动', KeepAliveCheckState.unknown,
          settingsTarget: 'autostart', manualConfirmable: true),
      item('battery_optimization', '忽略电池优化', KeepAliveCheckState.notOk,
          settingsTarget: 'battery'),
    ]);

    // 第一个「点击设置」对应渲染在前面的自启动项。
    await tester.tap(
      find.widgetWithText(OutlinedButton, '点击设置').first,
    );
    // 气泡由 AnimationController 驱动：用 pump，不用 pumpAndSettle。
    await tester.pump();
    await tester.pump();

    expect(checker.opened, <String>['autostart']);
    expect(find.text('已打开系统设置页'), findsOneWidget);

    await tester.pumpAndSettle();
  });

  testWidgets('勾选「我已完成」→ 写入手动确认并显示已完成',
      (WidgetTester tester) async {
    _useTallSurface(tester);
    final checker = await _pumpDetected(tester, <KeepAliveCheckItem>[
      item('auto_start', '允许自启动', KeepAliveCheckState.unknown,
          settingsTarget: 'autostart', manualConfirmable: true),
      item('notification', '允许通知', KeepAliveCheckState.ok),
    ]);

    await tester.tap(find.text('我已完成'));
    await tester.pumpAndSettle();

    expect(checker.confirmedWrites, <(String, bool)>[('auto_start', true)]);
    // 勾选后自启动项也按「已完成」展示（两处）。
    expect(find.text('已完成'), findsNWidgets(2));
  });

  testWidgets('手动确认持久化：已确认项进页面检测后仍勾选（退出再进仍在）',
      (WidgetTester tester) async {
    _useTallSurface(tester);
    final checker = _FakeChecker(
      <KeepAliveCheckItem>[
        item('auto_start', '允许自启动', KeepAliveCheckState.unknown,
            settingsTarget: 'autostart', manualConfirmable: true),
        item('notification', '允许通知', KeepAliveCheckState.ok),
      ],
      seedConfirms: <String, bool>{'auto_start': true},
    );

    CheckboxListTile box() => tester.widget<CheckboxListTile>(
          find.widgetWithText(CheckboxListTile, '我已完成'),
        );

    // 进入第一次：检测会清空落库旧值，但必须把恢复出来的确认重新应用/落库，
    // 否则勾选会被「检测」清掉。
    await tester.pumpWidget(_harness(checker));
    await tester.pumpAndSettle();
    await tester.tap(find.text('检测当前设置'));
    await tester.pumpAndSettle();
    expect(box().value, isTrue);
    expect(find.text('已完成'), findsNWidgets(2));

    // 退出页面（卸载）再重新进入：同一份持久化数据下，检测后勾选仍在。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(_harness(checker));
    await tester.pumpAndSettle();
    await tester.tap(find.text('检测当前设置'));
    await tester.pumpAndSettle();
    expect(box().value, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('品牌预选与测试提醒按钮渲染', (WidgetTester tester) async {
    _useTallSurface(tester);
    await tester.pumpWidget(_harness(_FakeChecker(const <KeepAliveCheckItem>[])));
    await tester.pumpAndSettle();

    // getManufacturer='Xiaomi' → 自动预选小米。
    final ChoiceChip chip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, '小米/红米'),
    );
    expect(chip.selected, isTrue);

    // 测试提醒入口保留（用于自证提醒是否真的响）。
    expect(find.text('发一条测试提醒'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('各品牌完整步骤原文仍在（切换品牌后可见）',
      (WidgetTester tester) async {
    _useTallSurface(tester);
    await tester.pumpWidget(
      _harness(_FakeChecker(const <KeepAliveCheckItem>[])),
    );
    await tester.pumpAndSettle();

    const Map<String, String> probe = <String, String>{
      '小米/红米': '省电策略',
      '华为': '休眠时始终保持网络连接',
      '荣耀': '手机管家',
      'OPPO': '耗电管理',
      'vivo': '后台耗电管理',
      '通用/其他': '特殊应用权限',
    };
    for (final MapEntry<String, String> e in probe.entries) {
      await tester.tap(find.widgetWithText(ChoiceChip, e.key));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(e.value),
        findsOneWidget,
        reason: '${e.key} 的步骤文案「${e.value}」丢失',
      );
    }
  });
}
