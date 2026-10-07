import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/holiday.dart';
import 'package:plai/data/models/period.dart';
import 'package:plai/data/models/semester.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/features/timetable/timetable_providers.dart';
import 'package:plai/features/timetable/week_view.dart';
import 'package:plai/shared/tab_reselect.dart';

/// 内存版设置仓库：只实现本用例需要的 [getAll]，其余抛未实现。
class _FakeSettings implements ISettingsRepository {
  @override
  Future<Map<String, String>> getAll() async => const <String, String>{};

  @override
  Future<String?> getValue(String key) async => null;

  @override
  Future<void> setValue(String key, String value) async =>
      throw UnimplementedError();

  @override
  Future<void> setAll(Map<String, String> entries) async =>
      throw UnimplementedError();

  @override
  Future<void> remove(String key) async => throw UnimplementedError();
}

/// 开学日 = 今天 → 当前周恒为第 1 周，用例不依赖运行日期。
Semester _semester() => Semester(
      name: '2026 秋',
      startDate: DateTime.now(),
      totalWeeks: 16,
    );

/// 单个节次（避免「暂无节次」空态，能渲染出完整周视图）。
List<Period> _periods() => <Period>[
      const Period(index: 1, startTime: '08:00', endTime: '08:45'),
    ];

/// 挂载周视图：全部数据 provider 直接覆盖为内存值，不建库、不发 I/O。
Future<void> _pumpWeekView(WidgetTester tester, {int? initialWeek}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        settingsRepositoryProvider.overrideWithValue(_FakeSettings()),
        coursesProvider.overrideWith((ref) => const <Course>[]),
        periodsProvider.overrideWith((ref) => _periods()),
        holidaysProvider.overrideWith((ref) => const <Holiday>[]),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: WeekView(semester: _semester(), initialWeek: initialWeek),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 卸载以取消 WeekView 的 Timer.periodic，避免收尾报 pending timer。
Future<void> _unmount(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

/// 周视图持有的 [PageController]（页 index = 周次 - 1）。
PageController _pageController(WidgetTester tester) =>
    tester.widget<PageView>(find.byType(PageView)).controller!;

/// 模拟「底部 tab 重按」：外壳只 bump 信号。
void _bumpTabReselect(WidgetTester tester) {
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(WeekView)),
    listen: false,
  );
  container.read(tabReselectProvider(kTimetableTabIndex).notifier).bump();
}

void main() {
  testWidgets('不在本周（第 15 周）：重按 → 平滑滑动回本周，一次动画到达', (
    WidgetTester tester,
  ) async {
    await _pumpWeekView(tester, initialWeek: 15);

    final PageController controller = _pageController(tester);
    // 初始在第 15 周（页 index 14）。
    expect(find.text('第 15 周'), findsOneWidget);
    expect(controller.page, closeTo(14.0, 0.001));

    _bumpTabReselect(tester);
    // 动画进行到约 250ms / 500ms（动画中点）：应处在两页之间的滑动途中（非瞬跳）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    final double mid = controller.page!;
    expect(mid, greaterThan(0.0));
    expect(mid, lessThan(14.0));

    // 一次 settle 即到达本周（不逐页播放）。
    await tester.pumpAndSettle();
    expect(controller.page, closeTo(0.0, 0.001));
    // 一致性：_week 与落到本周的页面同源 → 表头显示「第 1 周」，第 15 周已消失。
    expect(find.text('第 1 周'), findsOneWidget);
    expect(find.text('第 15 周'), findsNothing);

    await _unmount(tester);
  });

  testWidgets('已在当前周（第 1 周）：重按 → 无动作、无动画', (
    WidgetTester tester,
  ) async {
    await _pumpWeekView(tester, initialWeek: 1);

    final PageController controller = _pageController(tester);
    expect(controller.page, closeTo(0.0, 0.001));

    _bumpTabReselect(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // 位置不动、无进行中的滚动动画。
    expect(controller.page, closeTo(0.0, 0.001));
    expect(controller.position.isScrollingNotifier.value, isFalse);

    await _unmount(tester);
  });

  testWidgets('跳周输入框打开时重按 → 不复位（仍停在第 15 周）', (
    WidgetTester tester,
  ) async {
    await _pumpWeekView(tester, initialWeek: 15);

    final PageController controller = _pageController(tester);
    // 点表头「第 15 周」打开输入框。
    await tester.tap(find.text('第 15 周'));
    await tester.pumpAndSettle();
    expect(find.text('跳转到第几周'), findsOneWidget);

    _bumpTabReselect(tester);
    await tester.pumpAndSettle();

    // 对话框打开期间被重按：背景不跳走，仍在第 15 周。
    expect(find.text('第 15 周'), findsOneWidget);
    expect(controller.page, closeTo(14.0, 0.001));

    // 关闭对话框后收尾。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await _unmount(tester);
  });
}
