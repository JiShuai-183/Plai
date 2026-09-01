import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/features/settings/settings_page.dart';

void main() {
  testWidgets('设置页：出现「课表设置」分组及 6 项', (WidgetTester tester) async {
    // 高视口让 ListView 一次性构建全部分组项，避免懒加载漏查。
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: SettingsPage())),
    );
    await tester.pumpAndSettle();

    expect(find.text('课表设置'), findsOneWidget);
    expect(find.text('节次时间表'), findsOneWidget);
    expect(find.text('默认课程颜色'), findsOneWidget);
    expect(find.text('状态色总开关'), findsOneWidget);
    expect(find.text('正在上颜色'), findsOneWidget);
    expect(find.text('还未上颜色'), findsOneWidget);
    expect(find.text('已结束颜色'), findsOneWidget);
    expect(find.text('已结束文字淡化'), findsOneWidget);
    expect(find.text('已结束文字细化'), findsOneWidget);
  });
}
