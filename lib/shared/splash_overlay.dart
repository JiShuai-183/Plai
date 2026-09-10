import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/schedule/schedule_providers.dart';

/// 冷启动开屏：竖排「苦海无涯学做舟」自上而下逐字揭示。
///
/// 出现在 Flutter 首帧**之后**（它之前是原生启动窗口，底色与这里的
/// 底色一致，见 `android/app/src/main/res/values*/colors.xml`，不一致会
/// 先闪一块色再跳进动画）。
///
/// 兼作加载遮罩：书写动画至少播完才消退，今日数据就绪即淡出，把「今日」页
/// 原本的加载态藏在动画后面——开屏因此不是白等的时间。
class SplashOverlay extends ConsumerStatefulWidget {
  const SplashOverlay({super.key});

  /// 开屏标语（竖排，从上到下逐字写出）。
  static const String motto = '苦海无涯学做舟';

  /// 书写动画时长（全部字逐次揭示完）。
  static const Duration writeDuration = Duration(milliseconds: 1100);

  /// 消退淡出时长。
  static const Duration fadeDuration = Duration(milliseconds: 250);

  /// 书写已播完、但数据仍未就绪时的兜底等待上限，避免开屏被数据卡住。
  static const Duration dataWaitCap = Duration(milliseconds: 1300);

  @override
  ConsumerState<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends ConsumerState<SplashOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _write;
  late final AnimationController _fade;

  /// 数据未就绪时的兜底等待（只在「书写已播完但数据还没到」时才启动）。
  /// 用 Ticker 而非 `Timer`：由帧驱动，行为与 widget 测试的 `pump` 一致，
  /// 也不会在测试结束留下悬空 Timer。
  late final AnimationController _hold;

  late final CurvedAnimation _reveal;

  bool _started = false;
  bool _writeDone = false;
  bool _dataReady = false;
  bool _capFired = false;
  bool _finishing = false;

  /// 已完全消退：此后不再占位、不拦截触摸。
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _write =
        AnimationController(vsync: this, duration: SplashOverlay.writeDuration);
    _fade =
        AnimationController(vsync: this, duration: SplashOverlay.fadeDuration);
    _hold = AnimationController(
        vsync: this, duration: SplashOverlay.dataWaitCap);
    _reveal = CurvedAnimation(parent: _write, curve: Curves.easeOutCubic);
    _write.addStatusListener((AnimationStatus status) {
      if (status == AnimationStatus.completed) _onWriteCompleted();
    });
    _hold.addStatusListener((AnimationStatus status) {
      if (status == AnimationStatus.completed) {
        _capFired = true;
        _maybeFinish();
      }
    });
    _fade.addStatusListener((AnimationStatus status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _dismissed = true);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      // 系统开启「减少动画」：跳过书写过程，静态呈现后直接消退。
      _write.value = 1; // 会让揭示进度直接到 100%
      _onWriteCompleted();
    } else {
      _write.forward();
    }
  }

  @override
  void dispose() {
    _reveal.dispose();
    _write.dispose();
    _hold.dispose();
    _fade.dispose();
    super.dispose();
  }

  void _onWriteCompleted() {
    if (!mounted || _writeDone) return;
    _writeDone = true;
    if (!_dataReady) {
      // 书写已播完、数据还没到：起兜底等待，免得开屏被一直挂着。
      _hold.forward();
    }
    _maybeFinish();
  }

  /// 数据就绪（成功或失败都算——出错也不该让开屏继续挡着页面）。
  void _onDataSettled() {
    if (_dataReady) return;
    _dataReady = true;
    _hold.stop();
    _maybeFinish();
  }

  /// 消退条件：书写播完 且（数据就绪 或 兜底等待到点）。
  void _maybeFinish() {
    if (!mounted || _finishing || _dismissed) return;
    if (!_writeDone) return;
    if (!_dataReady && !_capFired) return;
    _finishing = true;
    _hold.stop();
    _fade.forward();
  }

  @override
  Widget build(BuildContext context) {
    // 订阅今日数据：开屏期间顺带把今日页的数据拉起来（与 app_shell 首帧后的
    // 预热共用同一 provider，不会重复取数）。
    final AsyncValue<TodayView> today = ref.watch(todayViewProvider);
    if (!today.isLoading && !_dataReady) {
      // 首帧即终态（例如测试环境无数据库）时不依赖后续变更回调；
      // 放到微任务里避免在 build 过程中改状态。
      scheduleMicrotask(_onDataSettled);
    }

    if (_dismissed) return const SizedBox.shrink();

    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color background =
        dark ? const Color(0xFF121212) : const Color(0xFFFAFAFA);
    final Color foreground =
        dark ? const Color(0xFFEDEDED) : const Color(0xFF1A1A1A);

    return Positioned.fill(
      child: AbsorbPointer(
        child: ColoredBox(
          color: background,
          child: FadeTransition(
            opacity: Tween<double>(begin: 1, end: 0).animate(_fade),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                // 竖排 7 字自适应：总高不超过屏高 62%、单字不超过屏宽 28%。
                final int count = SplashOverlay.motto.length;
                final double unit = math.min(
                  constraints.maxHeight * 0.62 / count,
                  constraints.maxWidth * 0.28,
                );
                final TextStyle style = TextStyle(
                  fontSize: unit * 0.86,
                  height: 1,
                  color: foreground,
                  fontWeight: FontWeight.w500,
                );
                return Center(
                  child: AnimatedBuilder(
                    animation: _reveal,
                    builder: (BuildContext context, Widget? child) {
                      // 用裁切（而非改尺寸）揭示：文字块位置固定，只有可见部分
                      // 自上而下增长，已显现的字不会随进度上下漂移。
                      return ClipRect(
                        clipper: TopRevealClipper(_reveal.value),
                        child: child,
                      );
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        for (int i = 0; i < count; i++) ...<Widget>[
                          if (i > 0) SizedBox(height: unit * 0.12),
                          Text(SplashOverlay.motto[i], style: style),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// 只保留顶部 [reveal] 比例（0~1）的裁切器：用于竖向逐字揭示。
class TopRevealClipper extends CustomClipper<Rect> {
  const TopRevealClipper(this.reveal);

  /// 揭示比例：0 = 全部遮住，1 = 全部显现。
  final double reveal;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width, size.height * reveal.clamp(0.0, 1.0));

  @override
  bool shouldReclip(TopRevealClipper oldClipper) =>
      oldClipper.reveal != reveal;
}
