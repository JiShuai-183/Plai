import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/features/settings/settings_page.dart';

void main() {
  testWidgets('设置页：出现「课表设置」入口', (WidgetTester tester) async {
    // 高视口让 ListView 一次性构建全部分组项，避免懒加载漏查。
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: SettingsPage())),
    );
    await tester.pumpAndSettle();

    expect(find.text('课表设置'), findsOneWidget);
    expect(find.text('课表颜色 · 状态色 · 节次时间'), findsOneWidget);

    // 节次/颜色/样式设置项已迁入新页面，不再出现在设置页。
    expect(find.text('节次时间表'), findsNothing);
    expect(find.text('默认课程颜色'), findsNothing);
    expect(find.text('状态色总开关'), findsNothing);
    expect(find.text('正在上课'), findsNothing);
  });
}
