import 'package:flutter/material.dart';

import 'layout_breakpoints.dart';

/// AppShell 底部导航栏（`NavigationBar(height: 64)`）高度；窄屏气泡需抬高避让。
const double _kBottomNavHeight = 64;

/// 气泡语义样式。
///
/// - [normal]：现有白底黑字气泡（成功 / 中性信息）。
/// - [error]：主题 `errorContainer` 醒目样式，带错误图标、停留更久。
enum PlaiToastKind { normal, error }

/// 气泡默认距屏幕底部偏移：宽屏（侧栏导航）为 24；窄屏在 24 基础上再抬高一个
/// 底部导航栏高度以避让 `AppShell` 的 `NavigationBar`，规则与 `AppShell` 保持一致。
double plaiToastBottomOffset(BuildContext context) {
  final bool isWide =
      MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint;
  return isWide ? 24 : 24 + _kBottomNavHeight;
}

/// 通用轻提示气泡：底部居中、圆角，淡出消失（不阻塞页面）。
/// [onDone] 在动画完成后回调（用于移除 [OverlayEntry]）。
///
/// 一般无需直接构造本组件，改用便捷入口 [showPlaiToast]。
class PlaiToast extends StatefulWidget {
  const PlaiToast({
    super.key,
    required this.message,
    required this.onDone,
    this.bottom,
    this.kind = PlaiToastKind.normal,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final VoidCallback onDone;

  /// 距屏幕底部偏移；null 时兜底 24。
  final double? bottom;

  final PlaiToastKind kind;

  /// 非空时在气泡右侧显示文字按钮。
  final String? actionLabel;

  /// 点击操作按钮的回调；点击后气泡立即消失。
  final VoidCallback? onAction;

  @override
  State<PlaiToast> createState() => _PlaiToastState();
}

class _PlaiToastState extends State<PlaiToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: widget.kind == PlaiToastKind.error
        ? const Duration(milliseconds: 3000)
        : const Duration(milliseconds: 1000),
  );

  bool get _hasAction => widget.actionLabel?.isNotEmpty == true;

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
    final bool isError = widget.kind == PlaiToastKind.error;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // normal 维持既有白底黑字（不随主题、不硬编码新增语义色）；
    // error 全部取自主题色。
    final Color background = isError ? scheme.errorContainer : Colors.white;
    final Color foreground = isError ? scheme.onErrorContainer : Colors.black;

    // normal 保持与旧实现逐像素一致：无图标且无操作按钮时直接用 Text。
    final Widget content;
    if (isError || _hasAction) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          if (isError) ...<Widget>[
            Icon(Icons.error_outline, size: 18, color: foreground),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              widget.message,
              style: TextStyle(
                color: foreground,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                decoration: TextDecoration.none,
              ),
            ),
          ),
          if (_hasAction) ...<Widget>[
            const SizedBox(width: 8),
            TextButton(
              onPressed: () {
                widget.onDone();
                widget.onAction?.call();
              },
              style: TextButton.styleFrom(
                foregroundColor: isError ? foreground : scheme.primary,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: Text(widget.actionLabel!),
            ),
          ],
        ],
      );
    } else {
      content = Text(
        widget.message,
        style: const TextStyle(
          color: Colors.black,
          fontSize: 14,
          fontWeight: FontWeight.w500,
          decoration: TextDecoration.none,
        ),
      );
    }

    // 长文案约束最大宽度（屏宽 - 48）并允许换行，避免溢出屏幕。
    final double maxWidth = MediaQuery.sizeOf(context).width - 48;

    Widget bubble = Padding(
      padding: EdgeInsets.only(bottom: widget.bottom ?? 24),
      child: FadeTransition(
        // normal：前 0.5s 恒显、后 0.5s 线性淡出。
        // error：前 0.8 恒显、后 0.2 淡出（更久停留，末尾淡出手感一致）。
        opacity: Tween<double>(begin: 1, end: 0).animate(
          CurvedAnimation(
            parent: _ctrl,
            curve: Interval(
              isError ? 0.8 : 0.5,
              1.0,
              curve: Curves.linear,
            ),
          ),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            // 圆角；normal 无阴影 / 无边框，避免与下方按钮边缘形成彩色线。
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(24),
            ),
            child: content,
          ),
        ),
      ),
    );

    // 有操作按钮时必须可点；无操作按钮时整体忽略指针，不拦截下方 UI。
    if (!_hasAction) {
      bubble = IgnorePointer(child: bubble);
    }

    return Align(alignment: Alignment.bottomCenter, child: bubble);
  }
}

/// 当前可见的气泡（用于去重：新提示插入前先移除旧的）。
OverlayEntry? _currentToastEntry;

/// 移除当前气泡（若仍在树上）。跨 Overlay 实例时 `entry.remove()` 亦正确。
void _dismissCurrentToast() {
  final OverlayEntry? entry = _currentToastEntry;
  _currentToastEntry = null;
  if (entry != null && entry.mounted) entry.remove();
}

/// 在屏幕底部居中弹出一次性轻提示（不阻塞页面）。调用方一行即可。
///
/// [bottom] 为距屏幕底部偏移；null 时用 [plaiToastBottomOffset] 的默认规则
/// （窄屏避让底部导航栏）。
///
/// [kind] 默认 [PlaiToastKind.normal]；错误场景传 [PlaiToastKind.error] 获得
/// 醒目样式与更长停留。
///
/// [actionLabel] 非空时右侧出现可点文字按钮，点击后气泡消失并回调 [onAction]。
///
/// **同一时刻只保留一个气泡**：调用本函数会先移除尚在显示的上一个气泡，
/// 避免连续提示在 40 处铺开后相互叠加。
///
/// [overlay] 为可选的挂载目标 Overlay，默认取 [Overlay.of]`(context)`。
/// **跨页面弹出时必须在 `Navigator.pop()` 之前取好 [OverlayState] 再传入本函数**：
/// 先 pop 返回上一页、再在那一页弹气泡的场景下，pop 之后当前 `context` 已失效，
/// 不能再调用 `Overlay.of(context)`。用法示例：
///
/// ```dart
/// final OverlayState overlay = Overlay.of(context);
/// Navigator.of(context).pop();
/// showPlaiToast(context, '保存成功', overlay: overlay);
/// ```
void showPlaiToast(
  BuildContext context,
  String message, {
  double? bottom,
  OverlayState? overlay,
  PlaiToastKind kind = PlaiToastKind.normal,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  _dismissCurrentToast();
  final OverlayState target = overlay ?? Overlay.of(context);
  final double resolvedBottom = bottom ?? plaiToastBottomOffset(context);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (BuildContext context) => PlaiToast(
      message: message,
      bottom: resolvedBottom,
      kind: kind,
      actionLabel: actionLabel,
      onAction: onAction,
      onDone: () {
        if (_currentToastEntry == entry) _currentToastEntry = null;
        if (entry.mounted) entry.remove();
      },
    ),
  );
  _currentToastEntry = entry;
  target.insert(entry);
}
