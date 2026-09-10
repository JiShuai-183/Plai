import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/task.dart';
import 'package:plai/features/schedule/schedule_providers.dart';
import 'package:plai/shared/splash_overlay.dart';

/// 把开屏放到与真实用法一致的位置（MaterialApp.builder 之上）。
Widget harness({Future<TodayView> Function(Ref ref)? today}) {
  return ProviderScope(
    overrides: <Override>[
      if (today != null) todayViewProvider.overrideWith(today),
    ],
    child: MaterialApp(
      builder: (BuildContext context, Widget? child) => Stack(
        children: <Widget>[?child, const SplashOverlay()],
      ),
      home: const Scaffold(body: Center(child: Text('主页'))),
    ),
  );
}

Future<TodayView> _ready(Ref ref) async =>
    const TodayView(courses: <TodayCourse>[], tasks: <Task>[]);

/// 页面上承载揭示裁切的那个 ClipRect（避开 Material 自带的 ClipRect）。
Finder get revealClip => find.byWidgetPredicate(
      (Widget w) => w is ClipRect && w.clipper is TopRevealClipper,
    );

double revealOf(WidgetTester tester) {
  final ClipRect clip = tester.widget<ClipRect>(revealClip);
  return (clip.clipper! as TopRevealClipper).reveal;
}

void main() {
  testWidgets('开屏竖排标语：7 个字逐字自上而下揭示', (WidgetTester tester) async {
    await tester.pumpWidget(harness(today: _ready));
    await tester.pump();

    // 首帧：尚未开始揭示。
    expect(revealOf(tester), 0.0);
    // 文字块一次排好（揭示靠裁切，不靠逐字插入）。
    for (final String ch in SplashOverlay.motto.split('')) {
      expect(find.text(ch), findsOneWidget);
    }

    // 写到一半：进度在 0~1 之间。
    await tester.pump(SplashOverlay.writeDuration ~/ 2);
    final double half = revealOf(tester);
    expect(half, greaterThan(0.0));
    expect(half, lessThan(1.0));

    // 写完：完全揭示。
    await tester.pump(SplashOverlay.writeDuration);
    expect(revealOf(tester), 1.0);
  });

  testWidgets('书写播完且数据就绪后，开屏淡出并不再占位',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness(today: _ready));
    await tester.pumpAndSettle();

    // 消退完成后不再渲染标语，也不拦截触摸。
    expect(revealClip, findsNothing);
    expect(find.text('主页'), findsOneWidget);
  });

  testWidgets('数据一直未就绪时，兜底上限到点仍会消退',
      (WidgetTester tester) async {
    // 永不完成的 Future：模拟数据迟迟不来。
    final Completer<TodayView> never = Completer<TodayView>();
    await tester.pumpWidget(harness(today: (Ref ref) => never.future));
    await tester.pump();

    // 书写播完那一刻还在（等数据）。
    await tester.pump(SplashOverlay.writeDuration);
    expect(revealClip, findsOneWidget);
    expect(revealOf(tester), 1.0);

    // 数据始终不来 → 兜底等待到点后仍会淡出消退。
    // （用 pumpAndSettle 推进，而非按毫秒硬 pump：兜底与淡出都由 Ticker 驱动，
    //   启动后的基线帧在下一帧才建立，按毫秒硬 pump 会少推一帧。）
    await tester.pumpAndSettle();
    expect(revealClip, findsNothing);

    never.complete(const TodayView(courses: <TodayCourse>[], tasks: <Task>[]));
  });

  testWidgets('系统「减少动画」开启时跳过书写过程', (WidgetTester tester) async {
    // 开屏读的是 MediaQuery.disableAnimations，其源头是平台无障碍设置；
    // 必须在下方的 MaterialApp 之前生效，故走平台层而非包一层 MediaQuery。
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    await tester.pumpWidget(harness(today: _ready));
    await tester.pump();

    // 不做逐字揭示，直接整句呈现。
    expect(revealOf(tester), 1.0);
  });
}
