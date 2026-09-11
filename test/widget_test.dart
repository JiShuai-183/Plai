import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/features/ai/ai_page.dart';
import 'package:plai/features/schedule/schedule_page.dart';
import 'package:plai/features/timetable/timetable_page.dart';
import 'package:plai/main.dart';

void main() {
  testWidgets('骨架：App 可启动，底部导航含三个 Tab（课表 / 今日 / AI）', (
    WidgetTester tester,
  ) async {
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

  testWidgets('宽屏：使用固定左侧导航，不显示手机底栏', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const ProviderScope(child: PlaiApp()));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byTooltip('最小化'), findsNothing);
    expect(find.byTooltip('最大化'), findsNothing);
    expect(find.byTooltip('关闭'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('课表'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('宽屏：AI 设置入口固定在左侧栏底部', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const ProviderScope(child: PlaiApp()));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('AI'),
      ),
    );
    await tester.pumpAndSettle();

    // 仅保留侧边栏的设置按钮，AI 顶栏不再重复显示齿轮。
    final Finder settings = find.byTooltip('设置');
    expect(settings, findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppBar), matching: settings),
      findsNothing,
    );
    expect(tester.getTopLeft(settings).dy, greaterThan(600));

    await tester.tap(settings);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '设置'), findsOneWidget);
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
    expect(find.text('开始一段对话吧'), findsOneWidget);

    // 齿轮（tooltip 设置）→ 打开设置页。
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '设置'), findsOneWidget);

    // 返回后回到 AI 页。
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('开始一段对话吧'), findsOneWidget);
  });

  testWidgets('冷启动落地「今日」，其余 Tab 懒构建、访问后保留在树中', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: PlaiApp()));
    await tester.pumpAndSettle();

    // 首帧只建落地页「今日」（使用频率最高）；未访问的 Tab 不构建，其
    // provider 取数（课表 / AI 会话全表）也不会白跑。
    expect(find.byType(SchedulePage), findsOneWidget);
    expect(find.byType(TimetablePage), findsNothing);
    expect(find.byType(AiPage), findsNothing);

    // 首次切到 AI 才真正构建。
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('AI'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AiPage), findsOneWidget);

    // 切回今日：AI 页仍留在树中（状态与 provider 缓存不丢，再切回无需重载）。
    // IndexedStack 把未选中页置为 offstage，故断言时需 skipOffstage: false。
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('今日'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AiPage, skipOffstage: false), findsOneWidget);
    expect(find.byType(SchedulePage), findsOneWidget);
  });
}
