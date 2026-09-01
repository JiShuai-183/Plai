import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/features/settings/timetable_settings_page.dart';

void main() {
  testWidgets('课表设置页：DB 不可用时三组标题与全部设置项正常渲染',
      (WidgetTester tester) async {
    // 高视口让 ListView 一次性构建全部分组项，避免懒加载漏查。
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 无 DB（宿主测试环境）→ provider 兜底默认值、节次数兜底 0，页面照常渲染。
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: TimetableSettingsPage())),
    );
    await tester.pumpAndSettle();

    // 三个分组标题：节次时间表标题与入口 ListTile 标题各一，共 2 个。
    expect(find.text('节次时间表'), findsNWidgets(2));
    expect(find.text('课表颜色'), findsOneWidget);
    expect(find.text('样式'), findsOneWidget);

    // 课表颜色组：三种状态色。
    expect(find.text('正在上颜色'), findsOneWidget);
    expect(find.text('还未上颜色'), findsOneWidget);
    expect(find.text('已结束颜色'), findsOneWidget);

    // 样式组：默认课程颜色 / 状态色总开关 / 已结束文字淡化 / 已结束文字细化。
    expect(find.text('默认课程颜色'), findsOneWidget);
    expect(find.text('状态色总开关'), findsOneWidget);
    expect(find.text('已结束文字淡化'), findsOneWidget);
    expect(find.text('已结束文字细化'), findsOneWidget);

    // 节次时间表入口副标题（兜底 0 节）。
    expect(find.text('共 0 节 · 编辑各节起止时间'), findsOneWidget);
  });
}
