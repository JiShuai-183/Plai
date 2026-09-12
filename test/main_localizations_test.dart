import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/main.dart';

/// 回归：`MaterialApp` 必须挂上全局中文本地化委托，否则 Flutter 内置组件
/// （最典型的是 `showDatePicker` 的日历卡）会回落成英文。
///
/// 本用例**复用 `main.dart` 的同一份常量**构造 `MaterialApp`，而不是另写一套
/// 配置 —— 这样将来有人误删某个 delegate 或改错 locale，本用例会立刻失败，
/// 不会出现「生产配错了但测试自己另配一套仍全绿」的假通过。
void main() {
  testWidgets('全局中文本地化：showDatePicker 显示中文，不出现英文默认文案', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: appLocale,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showDatePicker(
                  context: context,
                  initialDate: DateTime(2026, 9, 12),
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2030),
                ),
                child: const Text('打开日历'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('打开日历'));
    await tester.pumpAndSettle();

    // 中文默认按钮：取消 / 确定。
    expect(find.text('取消'), findsOneWidget,
        reason: '日期选择器取消按钮应为中文（缺少本地化委托时为 Cancel）');
    expect(find.text('确定'), findsOneWidget,
        reason: '日期选择器确认按钮应为中文（缺少本地化委托时为 OK）');

    // 英文默认文案绝不应出现。
    expect(find.text('Cancel'), findsNothing,
        reason: '出现英文 Cancel 说明本地化委托缺失');
    expect(find.text('OK'), findsNothing,
        reason: '出现英文 OK 说明本地化委托缺失');

    // 月份/表头走中文：标题栏含「年」「月」，星期表头为「日一二三四五六」。
    expect(find.textContaining('年'), findsWidgets,
        reason: '日期选择器标题应为中文（含「年」）');
    for (final String weekday in <String>['日', '一', '二', '三', '四', '五', '六']) {
      expect(find.text(weekday), findsWidgets,
          reason: '中文星期表头应包含「$weekday」');
    }
  });
}
