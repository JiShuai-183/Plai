import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/shared/plai_time_picker.dart';

/// 测试宿主：按钮点击后调用 showPlaiTimePicker，把结果回传给 onResult。
class _Harness extends StatelessWidget {
  const _Harness({this.initial, this.helpText, required this.onResult});

  final TimeOfDay? initial;
  final String? helpText;
  final ValueChanged<TimeOfDay?> onResult;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              final TimeOfDay? result = await showPlaiTimePicker(
                context,
                initialTime: initial,
                helpText: helpText,
              );
              onResult(result);
            },
            child: const Text('打开'),
          ),
        ),
      ),
    );
  }
}

/// 弹起选择器。通过 MaterialApp.builder 在 Navigator 之上覆写
/// alwaysUse24HourFormat，使对话框（含路由弹层）读到确定的时间制式。
Future<void> _pumpPicker(
  WidgetTester tester, {
  required bool use24h,
  TimeOfDay? initial,
  String? helpText,
  required ValueChanged<TimeOfDay?> onResult,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: use24h),
        child: child!,
      ),
      home: _Harness(initial: initial, helpText: helpText, onResult: onResult),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

/// 读取拨盘 painter（盘面模式等状态从 painter 字段验证）。
PlaiTimeDialPainter _painterOf(WidgetTester tester) {
  final CustomPaint paint = tester.widget<CustomPaint>(
    find.byKey(const Key('plai_dial_paint')),
  );
  return paint.painter! as PlaiTimeDialPainter;
}

void main() {
  group('PlaiTimeDialPainter.valueForAngle（角度 → 值，吸附 + 环绕）', () {
    test('顶部（12 点方向）对应 0 值', () {
      expect(PlaiTimeDialPainter.valueForAngle(math.pi / 2, 60), 0);
      expect(PlaiTimeDialPainter.valueForAngle(math.pi / 2, 12), 0);
    });

    test('顺时针一格吸附到下一值', () {
      expect(
        PlaiTimeDialPainter.valueForAngle(math.pi / 2 - 2 * math.pi / 60, 60),
        1,
      );
      expect(
        PlaiTimeDialPainter.valueForAngle(math.pi / 2 - 2 * math.pi / 12, 12),
        1,
      );
    });

    test('环绕：0 分左邻 = 59，59 分右邻 = 0', () {
      // 0 分逆时针一格（往左）
      expect(
        PlaiTimeDialPainter.valueForAngle(math.pi / 2 + 2 * math.pi / 60, 60),
        59,
      );
      // 59 分顺时针一格（往右）→ 0
      expect(
        PlaiTimeDialPainter.valueForAngle(
          math.pi / 2 - 59 * (2 * math.pi / 60) - 2 * math.pi / 60,
          60,
        ),
        0,
      );
    });

    test('两格正中点偏向一侧吸附', () {
      // 顶部顺时针 45° = 7.5 格 → 吸附到 8
      expect(
        PlaiTimeDialPainter.valueForAngle(math.pi / 2 - math.pi / 4, 60),
        8,
      );
      // 顶部顺时针 1.5 格 → 吸附到 2
      expect(
        PlaiTimeDialPainter.valueForAngle(
          math.pi / 2 - 1.5 * (2 * math.pi / 12),
          12,
        ),
        2,
      );
    });
  });

  group('PlaiTimeDialPainter.isOuterRing（24h 内外环判断）', () {
    const double labelRadius = 200.0;
    final double innerLabelRadius = labelRadius - kDialRingGap;

    test('贴外环 → 外环（0-11）', () {
      expect(
        PlaiTimeDialPainter.isOuterRing(labelRadius, innerLabelRadius, labelRadius),
        isTrue,
      );
    });

    test('贴内环 → 内环（12-23）', () {
      expect(
        PlaiTimeDialPainter.isOuterRing(innerLabelRadius, innerLabelRadius, labelRadius),
        isFalse,
      );
    });

    test('中间偏内 → 内环，偏外 → 外环', () {
      expect(
        PlaiTimeDialPainter.isOuterRing(160.0, innerLabelRadius, labelRadius),
        isFalse,
      );
      expect(
        PlaiTimeDialPainter.isOuterRing(196.0, innerLabelRadius, labelRadius),
        isTrue,
      );
    });

    test('中点等距视为外环', () {
      final double mid = (innerLabelRadius + labelRadius) / 2;
      expect(
        PlaiTimeDialPainter.isOuterRing(mid, innerLabelRadius, labelRadius),
        isTrue,
      );
    });
  });

  group('PlaiTimeDialPainter 12h/24h 转换', () {
    test('internalToTwelveHour', () {
      expect(PlaiTimeDialPainter.internalToTwelveHour(0), 12);
      expect(PlaiTimeDialPainter.internalToTwelveHour(12), 12);
      expect(PlaiTimeDialPainter.internalToTwelveHour(1), 1);
      expect(PlaiTimeDialPainter.internalToTwelveHour(13), 1);
      expect(PlaiTimeDialPainter.internalToTwelveHour(11), 11);
      expect(PlaiTimeDialPainter.internalToTwelveHour(23), 11);
    });

    test('twelveHourToInternal', () {
      expect(PlaiTimeDialPainter.twelveHourToInternal(12, isPm: false), 0);
      expect(PlaiTimeDialPainter.twelveHourToInternal(12, isPm: true), 12);
      expect(PlaiTimeDialPainter.twelveHourToInternal(1, isPm: false), 1);
      expect(PlaiTimeDialPainter.twelveHourToInternal(1, isPm: true), 13);
      expect(PlaiTimeDialPainter.twelveHourToInternal(11, isPm: true), 23);
    });

    test('isPm', () {
      expect(PlaiTimeDialPainter.isPm(0), isFalse);
      expect(PlaiTimeDialPainter.isPm(11), isFalse);
      expect(PlaiTimeDialPainter.isPm(12), isTrue);
      expect(PlaiTimeDialPainter.isPm(23), isTrue);
    });
  });

  group('showPlaiTimePicker 对话框', () {
    testWidgets('24h：弹起显示初始时间，点确定返回正确 TimeOfDay', (tester) async {
      TimeOfDay? result;
      await _pumpPicker(
        tester,
        use24h: true,
        initial: const TimeOfDay(hour: 14, minute: 30),
        onResult: (TimeOfDay? v) => result = v,
      );

      // 拨盘数字为 canvas 绘制，find.text 只命中头部时间段
      expect(find.text('14'), findsOneWidget);
      expect(find.text('30'), findsOneWidget);
      // 初始为小时盘，且为 24h 双环
      final PlaiTimeDialPainter p = _painterOf(tester);
      expect(p.mode, PlaiDialMode.hour);
      expect(p.use24h, isTrue);

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(result, const TimeOfDay(hour: 14, minute: 30));
    });

    testWidgets('12h：弹起显示 12h 小时 + AM/PM，点确定返回原始 24h 时间', (tester) async {
      TimeOfDay? result;
      await _pumpPicker(
        tester,
        use24h: false,
        initial: const TimeOfDay(hour: 14, minute: 30),
        onResult: (TimeOfDay? v) => result = v,
      );

      expect(find.text('2'), findsOneWidget);
      expect(find.text('30'), findsOneWidget);
      expect(find.text('AM'), findsOneWidget);
      expect(find.text('PM'), findsOneWidget);
      expect(_painterOf(tester).use24h, isFalse);

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(result, const TimeOfDay(hour: 14, minute: 30));
    });

    testWidgets('点取消返回 null', (tester) async {
      TimeOfDay? result = const TimeOfDay(hour: 8, minute: 0);
      await _pumpPicker(
        tester,
        use24h: true,
        initial: const TimeOfDay(hour: 8, minute: 5),
        onResult: (TimeOfDay? v) => result = v,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });

    testWidgets('helpText 作为对话框标题显示', (tester) async {
      await _pumpPicker(
        tester,
        use24h: true,
        initial: const TimeOfDay(hour: 9, minute: 0),
        helpText: '第 3 节开始时间',
        onResult: (_) {},
      );
      expect(find.text('第 3 节开始时间'), findsOneWidget);
    });

    testWidgets('点头部分钟段/小时段切换盘面模式', (tester) async {
      await _pumpPicker(
        tester,
        use24h: true,
        initial: const TimeOfDay(hour: 14, minute: 30),
        onResult: (_) {},
      );
      expect(_painterOf(tester).mode, PlaiDialMode.hour);

      await tester.tap(find.text('30'));
      await tester.pump();
      expect(_painterOf(tester).mode, PlaiDialMode.minute);

      await tester.tap(find.text('14'));
      await tester.pump();
      expect(_painterOf(tester).mode, PlaiDialMode.hour);
    });

    testWidgets('分钟盘：点击角度吸附到对应分钟', (tester) async {
      TimeOfDay? result;
      await _pumpPicker(
        tester,
        use24h: true,
        initial: const TimeOfDay(hour: 14, minute: 30),
        onResult: (TimeOfDay? v) => result = v,
      );
      await tester.tap(find.text('30'));
      await tester.pump();
      expect(_painterOf(tester).mode, PlaiDialMode.minute);

      // 点击顶部顺时针 5 格（= 分钟 5）位置
      final Rect dial = tester.getRect(find.byKey(const Key('plai_dial_paint')));
      final Offset center = dial.center;
      final double r = dial.width / 2 - kDialPadding;
      final double theta = math.pi / 2 - 5 * (2 * math.pi / 60);
      final Offset target =
          center + Offset(r * math.cos(theta), -r * math.sin(theta));
      await tester.tapAt(target);
      await tester.pump();

      expect(find.text('05'), findsOneWidget);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(result, const TimeOfDay(hour: 14, minute: 5));
    });

    testWidgets('24h：点外环数字选 0-11，点内环数字选 12-23', (tester) async {
      // 外环：i=3 → 3 点
      TimeOfDay? outerResult;
      await _pumpPicker(
        tester,
        use24h: true,
        initial: const TimeOfDay(hour: 14, minute: 0),
        onResult: (TimeOfDay? v) => outerResult = v,
      );
      final Rect dial = tester.getRect(find.byKey(const Key('plai_dial_paint')));
      final Offset center = dial.center;
      final double labelRadius = dial.width / 2 - kDialPadding;
      final double theta3 = math.pi / 2 - 3 * (2 * math.pi / 12);
      await tester.tapAt(center +
          Offset(labelRadius * math.cos(theta3), -labelRadius * math.sin(theta3)));
      await tester.pump();
      expect(find.text('03'), findsOneWidget);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(outerResult, const TimeOfDay(hour: 3, minute: 0));

      // 内环：i=1 → 13 点
      TimeOfDay? innerResult;
      await _pumpPicker(
        tester,
        use24h: true,
        initial: const TimeOfDay(hour: 14, minute: 0),
        onResult: (TimeOfDay? v) => innerResult = v,
      );
      final Rect dial2 = tester.getRect(find.byKey(const Key('plai_dial_paint')));
      final Offset center2 = dial2.center;
      final double labelRadius2 = dial2.width / 2 - kDialPadding;
      final double innerRadius2 = labelRadius2 - kDialRingGap;
      final double theta1 = math.pi / 2 - 1 * (2 * math.pi / 12);
      await tester.tapAt(center2 +
          Offset(innerRadius2 * math.cos(theta1), -innerRadius2 * math.sin(theta1)));
      await tester.pump();
      expect(find.text('13'), findsOneWidget);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(innerResult, const TimeOfDay(hour: 13, minute: 0));
    });

    testWidgets('12h：点 PM/AM 切换上下午并正确换算', (tester) async {
      // 8:00 AM → 点 PM → 20:00
      TimeOfDay? pmResult;
      await _pumpPicker(
        tester,
        use24h: false,
        initial: const TimeOfDay(hour: 8, minute: 0),
        onResult: (TimeOfDay? v) => pmResult = v,
      );
      await tester.tap(find.text('PM'));
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(pmResult, const TimeOfDay(hour: 20, minute: 0));

      // 20:00（PM）→ 点 AM → 8:00
      TimeOfDay? amResult;
      await _pumpPicker(
        tester,
        use24h: false,
        initial: const TimeOfDay(hour: 20, minute: 0),
        onResult: (TimeOfDay? v) => amResult = v,
      );
      await tester.tap(find.text('AM'));
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(amResult, const TimeOfDay(hour: 8, minute: 0));
    });

    testWidgets('极矮视口（480×320）：24h 弹起不抛异常、无 overflow、内圈半径恒正',
        (tester) async {
      tester.view.physicalSize = const Size(480, 320);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _pumpPicker(
        tester,
        use24h: true,
        initial: const TimeOfDay(hour: 14, minute: 30),
        onResult: (_) {},
      );
      // 无 overflow / 布局异常
      expect(tester.takeException(), isNull);

      // painter 按 dialSide（≥ kDialMinSide）坐标系绘制，内圈半径恒正
      final CustomPaint dialPaint = tester.widget<CustomPaint>(
        find.byKey(const Key('plai_dial_paint')),
      );
      expect(dialPaint.size.width, greaterThanOrEqualTo(kDialMinSide));
      final double innerRadius =
          dialPaint.size.width / 2 - kDialPadding - kDialRingGap;
      expect(innerRadius, greaterThanOrEqualTo(0));
    });

    testWidgets('点击分钟 15：指示器吸附到精确位置，Header 更新', (tester) async {
      TimeOfDay? result;
      await _pumpPicker(
        tester,
        use24h: true,
        initial: const TimeOfDay(hour: 14, minute: 0),
        onResult: (TimeOfDay? v) => result = v,
      );
      await tester.tap(find.text('00'));
      await tester.pump();
      expect(_painterOf(tester).mode, PlaiDialMode.minute);

      final Rect dial = tester.getRect(find.byKey(const Key('plai_dial_paint')));
      final Offset center = dial.center;
      final double r = dial.width / 2 - kDialPadding;
      final double theta = math.pi / 2 - 15 * (2 * math.pi / 60);
      final Offset target =
          center + Offset(r * math.cos(theta), -r * math.sin(theta));
      await tester.tapAt(target);
      await tester.pumpAndSettle();

      // 抬起后指示器平滑滑到精确数值位置
      final PlaiTimeDialPainter p = _painterOf(tester);
      expect(p.indicatorTheta, isNotNull);
      expect(p.indicatorTheta!, closeTo(theta, 1e-6));
      expect(p.indicatorRadius!, closeTo(r, 1e-6));
      expect(find.text('15'), findsOneWidget);

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(result, const TimeOfDay(hour: 14, minute: 15));
    });

    testWidgets('拖动手感：指示器跟随手指，抬起后吸附到精确值', (tester) async {
      TimeOfDay? result;
      await _pumpPicker(
        tester,
        use24h: true,
        initial: const TimeOfDay(hour: 14, minute: 0),
        onResult: (TimeOfDay? v) => result = v,
      );
      await tester.tap(find.text('00'));
      await tester.pump();
      expect(_painterOf(tester).mode, PlaiDialMode.minute);

      final Rect dial = tester.getRect(find.byKey(const Key('plai_dial_paint')));
      final Offset center = dial.center;
      final double r = dial.width / 2 - kDialPadding;
      double thetaOf(int minute) => math.pi / 2 - minute * (2 * math.pi / 60);
      Offset posOf(int minute) => center +
          Offset(r * math.cos(thetaOf(minute)), -r * math.sin(thetaOf(minute)));

      final TestGesture gesture = await tester.startGesture(posOf(5));
      await gesture.moveTo(posOf(25));
      await tester.pump();

      // 未抬起：指示器跟随手指（介于两位置之间），Header 已同步新值
      final PlaiTimeDialPainter dragging = _painterOf(tester);
      expect(dragging.indicatorTheta, isNotNull);
      expect(
        dragging.indicatorTheta!,
        inInclusiveRange(thetaOf(25), thetaOf(5)),
      );
      expect(dragging.indicatorTheta!, isNot(closeTo(thetaOf(5), 0.05)));
      expect(find.text('25'), findsOneWidget);

      await gesture.up();
      await tester.pumpAndSettle();
      final PlaiTimeDialPainter settled = _painterOf(tester);
      expect(settled.indicatorTheta!, closeTo(thetaOf(25), 1e-6));
      expect(settled.indicatorRadius!, closeTo(r, 1e-6));

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(result, const TimeOfDay(hour: 14, minute: 25));
    });

    testWidgets('划出盘面：绿圆贴边继续跟角度，半径不超拨盘，值随角度更新', (tester) async {
      TimeOfDay? result;
      await _pumpPicker(
        tester,
        use24h: true,
        initial: const TimeOfDay(hour: 14, minute: 0),
        onResult: (TimeOfDay? v) => result = v,
      );
      final Rect dial = tester.getRect(find.byKey(const Key('plai_dial_paint')));
      final Offset center = dial.center;
      final double r = dial.width / 2 - kDialPadding; // labelRadius
      double thetaOf(int h) => math.pi / 2 - h * (2 * math.pi / 12);

      // 从盘内小时 3（外环，正右方）按下，再划到盘外小时 9 方向（正左方）
      final TestGesture gesture = await tester.startGesture(
        center + Offset(r * math.cos(thetaOf(3)), -r * math.sin(thetaOf(3))),
      );
      await tester.pump();
      final Offset outside = center +
          Offset((r + 80) * math.cos(thetaOf(9)), -(r + 80) * math.sin(thetaOf(9)));
      await gesture.moveTo(outside);
      await tester.pump();

      final PlaiTimeDialPainter dragging = _painterOf(tester);
      // 绿圆圆心不超数字环（最多与盘底圆内缘相切），贴到 labelRadius
      expect(dragging.indicatorRadius!, lessThanOrEqualTo(r + 0.5));
      expect(dragging.indicatorRadius!, closeTo(r, 1.0));
      // 角度仍跟随手指（正左方），用 cos/sin 断言避免 ±π 表示差异
      expect(math.cos(dragging.indicatorTheta!), closeTo(-1.0, 0.05));
      expect(math.sin(dragging.indicatorTheta!), closeTo(0.0, 0.05));
      // 值随角度更新（外环 hour 9）
      expect(find.text('09'), findsOneWidget);

      await gesture.up();
      await tester.pumpAndSettle();
      final PlaiTimeDialPainter settled = _painterOf(tester);
      expect(math.cos(settled.indicatorTheta!), closeTo(-1.0, 1e-4));
      expect(settled.indicatorRadius!, closeTo(r, 1e-4));
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(result, const TimeOfDay(hour: 9, minute: 0));
    });
  });

  group('PlaiTimeDialPainter 指示器回退', () {
    test('无 indicator 覆盖时按 hour/minute 回退绘制不崩（24h 内环 hour=13）', () {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final ui.Canvas canvas = ui.Canvas(recorder);
      final PlaiTimeDialPainter painter = PlaiTimeDialPainter(
        mode: PlaiDialMode.hour,
        use24h: true,
        hour: 13,
        minute: 0,
        colorScheme:
            ColorScheme.fromSeed(seedColor: const Color(0xFF43A047)),
        textScaler: TextScaler.noScaling,
      );
      expect(painter.indicatorTheta, isNull);
      expect(painter.indicatorRadius, isNull);
      painter.paint(canvas, const Size(320, 320));
    });
  });
}
