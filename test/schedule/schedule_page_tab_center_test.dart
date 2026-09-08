import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/data/models/period.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/features/schedule/date_strip.dart';
import 'package:plai/features/schedule/schedule_page.dart';
import 'package:plai/features/schedule/schedule_providers.dart';
import 'package:plai/features/timetable/timetable_providers.dart';

/// 复现「进入今日页」路径：今日页在 IndexedStack 中预构建/常驻，
/// 每次它被选中（appTabIndex→1）都应收起把日期条「今天」回中。
void main() {
  Key dayKey(DateTime d) =>
      ValueKey<String>('day_${d.year}_${d.month}_${d.day}');

  DateTime todayOf() {
    final DateTime n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  Widget app(int index) {
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
        timetableStatusSettingsProvider
            .overrideWith((ref) async => settings),
        dailyDoneMapProvider.overrideWith(
            (ref) async => const <int, Set<DateTime>>{}),
      ],
      child: MaterialApp(
        home: IndexedStack(
          index: index,
          children: <Widget>[
            const SizedBox(),
            const SchedulePage(),
          ],
        ),
      ),
    );
  }

  void expectCentered(WidgetTester tester, DateTime today) {
    final Rect strip = tester.getRect(find.byType(DateStrip));
    final Rect cell = tester.getRect(find.byKey(dayKey(today)));
    final double diff = (cell.center.dx - strip.center.dx).abs();
    expect(diff, lessThan(23),
        reason: '今天应居中：cellCenter=${cell.center.dx} '
            'stripCenter=${strip.center.dx} diff=$diff');
  }

  void usePhoneWidth(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('冷启动预构建后首次切到今日：日期条今天居中（首帧校准一次）', (WidgetTester tester) async {
    usePhoneWidth(tester);
    int index = 0;
    late StateSetter setOuter;
    await tester.pumpWidget(StatefulBuilder(
      builder: (BuildContext context, StateSetter setStateOuter) {
        setOuter = setStateOuter;
        return app(index);
      },
    ));
    await tester.pumpAndSettle();

    // 首次切入今日（仅切 IndexedStack；不再有「每次进 tab 回中」逻辑）。
    setOuter(() => index = 1);
    await tester.pump();
    await tester.pumpAndSettle();
    expectCentered(tester, todayOf());
  });
}
