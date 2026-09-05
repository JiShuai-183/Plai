import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/main.dart';

void main() {
  testWidgets('骨架：App 可启动，底部导航含三个 Tab（课表 / 今日 / AI）',
      (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: PlaiApp()));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(3));
    expect(find.byType(IndexedStack), findsOneWidget);

    // 三个 Tab label：课表 / 今日 / AI（设置已迁出 Tab，改从 AI 页齿轮进入）。
    expect(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('课表'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('今日'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('AI'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('设置'),
      ),
      findsNothing,
    );
  });

  testWidgets('AI 页齿轮可 push 打开设置页（带返回）', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: PlaiApp()));
    await tester.pumpAndSettle();

    // 切到第 3 个 Tab（AI）。
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('AI'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('AI 功能准备中'), findsOneWidget);

    // 齿轮（tooltip 设置）→ 打开设置页。
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '设置'), findsOneWidget);

    // 返回后回到 AI 页。
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('AI 功能准备中'), findsOneWidget);
  });
}
