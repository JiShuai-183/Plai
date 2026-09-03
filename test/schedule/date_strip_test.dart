import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/features/schedule/date_strip.dart';

void main() {
  /// 收窄视口到 360 宽，让 17 天窗口（748px）可横向滚动，检验居中定位。
  void narrowView(WidgetTester tester) {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget wrap(
    DateTime today,
    DateTime selected,
    ValueChanged<DateTime> onDaySelected,
  ) {
    return MaterialApp(
      home: Scaffold(
        body: DateStrip(
          today: today,
          selected: selected,
          onDaySelected: onDaySelected,
        ),
      ),
    );
  }

  testWidgets('初次进入：今天默认居中且可见', (WidgetTester tester) async {
    narrowView(tester);
    final DateTime today = DateTime(2026, 9, 3);

    await tester.pumpWidget(wrap(today, today, (_) {}));
    await tester.pump();

    final Finder todayCell = find.byKey(const ValueKey<String>('day_2026_9_3'));
    expect(todayCell, findsOneWidget);
    // 首帧即停到居中位：今天格中心应贴近视口中心（360/2=180）。
    expect(tester.getCenter(todayCell).dx, closeTo(180, 40));
  });

  testWidgets('点选未来一天：回调返回该天', (WidgetTester tester) async {
    narrowView(tester);
    final DateTime today = DateTime(2026, 9, 3);
    DateTime? picked;

    await tester.pumpWidget(
      wrap(today, today, (DateTime day) => picked = day),
    );
    await tester.pump();

    final Finder tomorrow = find.byKey(const ValueKey<String>('day_2026_9_4'));
    expect(tomorrow, findsOneWidget);
    await tester.tap(tomorrow);
    await tester.pump();

    expect(picked, DateTime(2026, 9, 4));
  });

  testWidgets('点过去一天：回调返回该天', (WidgetTester tester) async {
    narrowView(tester);
    final DateTime today = DateTime(2026, 9, 3);
    DateTime? picked;

    await tester.pumpWidget(
      wrap(today, today, (DateTime day) => picked = day),
    );
    await tester.pump();

    final Finder yesterday =
        find.byKey(const ValueKey<String>('day_2026_9_2'));
    expect(yesterday, findsOneWidget);
    await tester.tap(yesterday);
    await tester.pump();

    expect(picked, DateTime(2026, 9, 2));
  });

  testWidgets('窗口两端日期齐全：今天±8 均渲染', (WidgetTester tester) async {
    narrowView(tester);
    final DateTime today = DateTime(2026, 9, 3);

    await tester.pumpWidget(wrap(today, today, (_) {}));
    await tester.pump();

    // 初始今天居中（offset≈194）；横向 ListView 懒加载，滑到最左看过去日。
    final Finder list = find.byType(ListView);
    await tester.drag(list, const Offset(1500, 0)); // 内容右移 → 到最左
    await tester.pumpAndSettle();
    final Finder mostLeft = find.byKey(const ValueKey<String>('day_2026_8_26'));
    expect(mostLeft, findsOneWidget);

    await tester.drag(list, const Offset(-3000, 0)); // 内容左移 → 到最右
    await tester.pumpAndSettle();
    final Finder mostRight =
        find.byKey(const ValueKey<String>('day_2026_9_11'));
    expect(mostRight, findsOneWidget);
  });
}
