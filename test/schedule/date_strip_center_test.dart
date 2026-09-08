import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/features/schedule/date_strip.dart';

/// 日期条「今天居中」几何断言：单独 pump DateStrip，量今天单元格中心是否
/// 落在条视口中央（偏移 > 一格即视为未居中）。
void main() {
  Widget wrap({required DateTime today, required DateTime selected, Object? centerKey}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            child: DateStrip(
              today: today,
              selected: selected,
              centerKey: centerKey,
              onDaySelected: (_) {},
            ),
          ),
        ),
      ),
    );
  }

  Key dayKey(DateTime d) =>
      ValueKey<String>('day_${d.year}_${d.month}_${d.day}');

  void expectCentered(WidgetTester tester, DateTime today) {
    final Rect strip = tester.getRect(find.byType(DateStrip));
    final Rect cell = tester.getRect(find.byKey(dayKey(today)));
    final double centerDx = cell.center.dx;
    final double stripCenterDx = strip.center.dx;
    // 允许半格以内误差（22px），超过即未居中。
    expect((centerDx - stripCenterDx).abs(),
        lessThan(23),
        reason: '今天应居中：cellCenter=$centerDx stripCenter=$stripCenterDx');
  }

  testWidgets('首帧：今天应居中', (WidgetTester tester) async {
    final DateTime today = DateTime(2026, 9, 8);
    await tester.pumpWidget(wrap(today: today, selected: today));
    await tester.pumpAndSettle();
    expectCentered(tester, today);
  });

  testWidgets('拖动后触发 centerKey → 今天回中', (WidgetTester tester) async {
    final DateTime today = DateTime(2026, 9, 8);
    // 用 StatefulBuilder 模拟父级改 centerKey。
    int tick = 0;
    late StateSetter setOuter;
    await tester.pumpWidget(StatefulBuilder(
      builder: (BuildContext context, StateSetter setStateOuter) {
        setOuter = setStateOuter;
        return wrap(
          today: today,
          selected: today,
          centerKey: tick,
        );
      },
    ));
    await tester.pumpAndSettle();

    // 把日期条往左拖开，让今天离开中央。
    await tester.drag(find.byType(DateStrip), const Offset(-500, 0));
    await tester.pumpAndSettle();
    final Rect strip = tester.getRect(find.byType(DateStrip));
    final Rect moved = tester.getRect(find.byKey(dayKey(today)));
    expect((moved.center.dx - strip.center.dx).abs(),
        greaterThan(100),
        reason: '拖动后今天应已偏离中央');

    // 外部触发回中。
    setOuter(() => tick++);
    await tester.pump();
    await tester.pumpAndSettle();
    expectCentered(tester, today);
  });
}
