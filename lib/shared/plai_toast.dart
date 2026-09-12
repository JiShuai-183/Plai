import 'package:flutter/material.dart';

/// 通用轻提示气泡：白底黑字圆角矩形，底部居中，1s 后淡化消失
/// （前 0.5s 提示不变，后 0.5s 逐渐淡化直到消失）。
/// [onDone] 在动画完成后回调（用于移除 [OverlayEntry]）。
///
/// 一般无需直接构造本组件，改用便捷入口 [showPlaiToast]。
class PlaiToast extends StatefulWidget {
  const PlaiToast({super.key, required this.message, required this.onDone, this.bottom});

  final String message;
  final VoidCallback onDone;

  /// 距屏幕底部偏移；null 时兜底 24。
  final double? bottom;

  @override
  State<PlaiToast> createState() => _PlaiToastState();
}

class _PlaiToastState extends State<PlaiToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void initState() {
    super.initState();
    _ctrl.addStatusListener((AnimationStatus status) {
      if (status == AnimationStatus.completed) widget.onDone();
    });
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: IgnorePointer(
        child: Padding(
          padding: EdgeInsets.only(bottom: widget.bottom ?? 24),
          child: FadeTransition(
            // 前 0.5s opacity 恒 1，后 0.5s 线性渐隐到 0。
            opacity: Tween<double>(begin: 1, end: 0).animate(
              CurvedAnimation(
                parent: _ctrl,
                curve: const Interval(0.5, 1.0, curve: Curves.linear),
              ),
            ),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              // 纯白底圆角，无阴影 / 无边框，避免与下方按钮边缘形成彩色线。
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Text(
                widget.message,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 在屏幕底部居中弹出一次性轻提示，1s 后自动消失（不阻塞页面）。调用方一行即可。
///
/// [bottom] 为距屏幕底部偏移（默认 24）；若页面底部有底部导航栏等需避让的元素，
/// 由调用方传入更大值。
///
/// [overlay] 为可选的挂载目标 Overlay，默认取 [Overlay.of]`(context)`。
/// **跨页面弹出时必须在 `Navigator.pop()` 之前取好 [OverlayState] 再传入本函数**：
/// 先 pop 返回上一页、再在那一页弹气泡的场景下，pop 之后当前 `context` 已失效，
/// 不能再调用 `Overlay.of(context)`。用法示例：
///
/// ```dart
/// final OverlayState overlay = Overlay.of(context);
/// final double bottom = ...; // 按页面布局算好
/// Navigator.of(context).pop();
/// showPlaiToast(context, '保存成功', bottom: bottom, overlay: overlay);
/// ```
void showPlaiToast(
  BuildContext context,
  String message, {
  double? bottom,
  OverlayState? overlay,
}) {
  final OverlayState target = overlay ?? Overlay.of(context);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (BuildContext context) => PlaiToast(
      message: message,
      bottom: bottom,
      onDone: () => entry.remove(),
    ),
  );
  target.insert(entry);
}
