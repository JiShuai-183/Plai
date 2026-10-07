import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/data/models/period.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/features/schedule/date_strip.dart';
import 'package:plai/features/schedule/schedule_page.dart';
import 'package:plai/features/schedule/schedule_providers.dart';
import 'package:plai/features/timetable/timetable_providers.dart';
import 'package:plai/shared/tab_reselect.dart';

/// 重按底部「今日」tab 的复位语义：
/// - 已在今天 → 无动作（不复位、不滚动）；
/// - 不在今天 → 复位回今天（日期条平滑回中，内容切到今天）。
void main() {
  Key dayKey(DateTime d) =>
      ValueKey<String>('day_${d.year}_${d.month}_${d.day}');

  DateTime todayOf() {
    final DateTime n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  Widget app() {
    final TimetableStatusSettings settings = const TimetableStatusSettings(
      statusColorsEnabled: false,
      ongoingColor: '',
      upcomingColor: '',
      finishedColor: '',
      finishedTextFade: false,
      finishedTextThin: false,
      defaultCourseColor: '',
    );
    return ProviderScope(
      overrides: [
        tasksProvider.overrideWith((ref) async => const <Task>[]),
        todayCoursesProvider.overrideWith((ref) async => const <TodayCourse>[]),
        dayCoursesProvider
            .overrideWith((ref, DateTime day) async => const <TodayCourse>[]),
        periodsProvider.overrideWith((ref) async => const <Period>[]),
        timetableStatusSettingsProvider.overrideWith((ref) async => settings),
        dailyDoneMapProvider
            .overrideWith((ref) async => const <int, Set<DateTime>>{}),
      ],
      child: const MaterialApp(home: SchedulePage()),
    );
  }

  /// 复现外壳「重按当前 tab」的动作：只 bump 信号。
  void bumpToday(WidgetTester tester) {
    ProviderScope.containerOf(
      tester.element(find.byType(SchedulePage)),
      listen: false,
    ).read(tabReselectProvider(kTodayTabIndex).notifier).bump();
  }

  void usePhoneWidth(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('拨到别的日期后重按今日 → 复位回今天，内容切回今天且日期条今天居中', (
    WidgetTester tester,
  ) async {
    usePhoneWidth(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    // 初始：选中今天 → 今日文案。
    expect(find.text('今日课程'), findsOneWidget);
    expect(find.text('今天没有课'), findsOneWidget);

    // 用既有交互（点日期条某天）切到「前天」。
    final DateTime today = todayOf();
    final DateTime other = DateTime(today.year, today.month, today.day - 2);
    await tester.tap(find.byKey(dayKey(other)));
    await tester.pumpAndSettle();

    expect(find.text('今日课程'), findsNothing);
    expect(find.text('这天没有课'), findsOneWidget);

    // 重按「今日」tab → 复位回今天。
    bumpToday(tester);
    await tester.pumpAndSettle();

    expect(find.text('今日课程'), findsOneWidget);
    expect(find.text('今天没有课'), findsOneWidget);
    expect(find.text('这天没有课'), findsNothing);

    // 日期条上今天应可见且居中（选中日切回今天触发平滑回中）。
    final Rect strip = tester.getRect(find.byType(DateStrip));
    final Rect cell = tester.getRect(find.byKey(dayKey(today)));
    expect(
      (cell.center.dx - strip.center.dx).abs(),
      lessThan(23),
      reason: '今天应回到日期条中央：cell=${cell.center.dx} '
          'strip=${strip.center.dx}',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('已在今天时重按今日 → 无动作：内容与日期条位置均不变', (
    WidgetTester tester,
  ) async {
    usePhoneWidth(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    // 先把日期条拖开，让今天离开中央（选中日仍是今天）。
    await tester.drag(find.byType(DateStrip), const Offset(-150, 0));
    await tester.pumpAndSettle();

    final DateTime today = todayOf();
    final Rect stripBefore = tester.getRect(find.byType(DateStrip));
    final Rect cellBefore = tester.getRect(find.byKey(dayKey(today)));
    final double offBefore = (cellBefore.center.dx - stripBefore.center.dx).abs();
    expect(offBefore, greaterThan(100), reason: '拖动后今天应已偏离中央');

    // 重按今日（当前已在今天）→ 应完全无动作。
    bumpToday(tester);
    await tester.pump(); // 单帧：若有滚动动画，此刻也不会瞬间回中。

    final Rect stripAfter = tester.getRect(find.byType(DateStrip));
    final Rect cellAfter = tester.getRect(find.byKey(dayKey(today)));
    expect(cellAfter.center.dx, closeTo(cellBefore.center.dx, 0.001));
    expect(stripAfter.center.dx, closeTo(stripBefore.center.dx, 0.001));
    expect(
      (cellAfter.center.dx - stripAfter.center.dx).abs(),
      closeTo(offBefore, 0.001),
      reason: '已在今天时不得复位/滚动',
    );
    expect(find.text('今日课程'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
