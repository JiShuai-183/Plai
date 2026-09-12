import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/shared/plai_toast.dart';

/// 测试宿主：整屏可点手势 + 一个触发按钮，方便验证气泡是否拦截下方 UI。
class _ToastHost extends StatelessWidget {
  const _ToastHost({required this.onBackgroundTap});

  final VoidCallback onBackgroundTap;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onBackgroundTap,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// 取得可发起 [showPlaiToast] 的上下文（MaterialApp 下的 Builder）。
BuildContext _hostContext(WidgetTester tester) =>
    tester.element(find.byType(Scaffold));

void main() {
  testWidgets('normal：渲染文案，1s 时长内可见后消失、无错误图标', (WidgetTester tester) async {
    await tester.pumpWidget(const _ToastHost(onBackgroundTap: _noop));

    showPlaiToast(_hostContext(tester), '保存成功');
    await tester.pump();

    expect(find.text('保存成功'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNothing);

    // 900ms 仍在 1s 时长内。
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.text('保存成功'), findsOneWidget);

    // 越过 1s 后动画完成、条目移除。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('保存成功'), findsNothing);
  });

  testWidgets('error：带错误图标、主题 errorContainer 底色，约 3s 才消失',
      (WidgetTester tester) async {
    await tester.pumpWidget(const _ToastHost(onBackgroundTap: _noop));

    showPlaiToast(
      _hostContext(tester),
      '保存失败',
      kind: PlaiToastKind.error,
    );
    await tester.pump();

    expect(find.text('保存失败'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);

    final ColorScheme scheme =
        Theme.of(tester.element(find.text('保存失败'))).colorScheme;
    final Container container = tester.widget<Container>(
      find
          .ancestor(of: find.text('保存失败'), matching: find.byType(Container))
          .first,
    );
    expect((container.decoration! as BoxDecoration).color, scheme.errorContainer);

    // 1500ms 已超过 normal 的 1s，但仍应可见。
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.text('保存失败'), findsOneWidget);

    // 越过 3s。
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pumpAndSettle();
    expect(find.text('保存失败'), findsNothing);
  });

  testWidgets('有 action：按钮可点并回调，点击后气泡消失', (WidgetTester tester) async {
    await tester.pumpWidget(const _ToastHost(onBackgroundTap: _noop));

    int actionCalls = 0;
    showPlaiToast(
      _hostContext(tester),
      '未配置',
      actionLabel: '去设置',
      onAction: () => actionCalls++,
    );
    await tester.pump();

    expect(find.text('去设置'), findsOneWidget);
    await tester.tap(find.text('去设置'));
    await tester.pump();

    expect(actionCalls, 1);
    await tester.pumpAndSettle();
    expect(find.text('未配置'), findsNothing);
  });

  testWidgets('无 action：IgnorePointer 生效，点击气泡区域穿透到下方 UI',
      (WidgetTester tester) async {
    int backgroundTaps = 0;
    await tester.pumpWidget(_ToastHost(onBackgroundTap: () => backgroundTaps++));

    showPlaiToast(_hostContext(tester), '保存成功');
    await tester.pump();

    // 直接点在气泡文案中心：应穿透到底层整屏手势。
    await tester.tapAt(tester.getCenter(find.text('保存成功')));
    await tester.pump();

    expect(backgroundTaps, 1);
    expect(find.text('保存成功'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('去重：连续两次弹出后只剩最新一个气泡', (WidgetTester tester) async {
    await tester.pumpWidget(const _ToastHost(onBackgroundTap: _noop));

    showPlaiToast(_hostContext(tester), '第一条');
    await tester.pump();
    expect(find.text('第一条'), findsOneWidget);

    showPlaiToast(_hostContext(tester), '第二条');
    await tester.pump();

    expect(find.text('第一条'), findsNothing);
    expect(find.text('第二条'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('第二条'), findsNothing);
  });

  testWidgets('长文案在窄屏内换行，不溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(300, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const _ToastHost(onBackgroundTap: _noop));

    showPlaiToast(
      _hostContext(tester),
      'CSV 不含学期信息，请先创建或切换到目标学期',
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('CSV 不含学期信息，请先创建或切换到目标学期'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

void _noop() {}
