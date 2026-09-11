import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Windows 无边框窗口的应用内控制栏。
///
/// 原生标题栏移除后，保留这条拖动区域及标准窗口控制，避免窗口
/// 不能移动、最小化或关闭。仅 Windows 宽屏外壳使用。
class DesktopWindowControls extends StatefulWidget {
  const DesktopWindowControls({super.key});

  @override
  State<DesktopWindowControls> createState() => _DesktopWindowControlsState();
}

class _DesktopWindowControlsState extends State<DesktopWindowControls> {
  static const MethodChannel _channel = MethodChannel('plai/window_controls');

  bool _maximized = false;

  Future<void> _startDrag() => _invoke('startDrag');

  Future<void> _minimize() => _invoke('minimize');

  Future<void> _toggleMaximize() async {
    try {
      final bool? maximized = await _channel.invokeMethod<bool>(
        'toggleMaximize',
      );
      if (mounted && maximized != null) {
        setState(() => _maximized = maximized);
      }
    } on PlatformException {
      // 非 Windows 测试宿主没有原生通道，保持当前外观即可。
    } on MissingPluginException {
      // 同上：不影响页面主体。
    }
  }

  Future<void> _close() => _invoke('close');

  Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on PlatformException {
      // 原生窗口调用失败时不让 UI 抛错。
    } on MissingPluginException {
      // Widget test / 非 Windows 平台无原生实现。
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return const SizedBox.shrink();

    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextStyle logoStyle =
        (Theme.of(context).textTheme.titleLarge ??
                const TextStyle(fontSize: 22))
            .copyWith(
              fontSize:
                  (Theme.of(context).textTheme.titleLarge?.fontSize ?? 22) *
                  1.5,
              height: 1,
            );
    return Material(
      color: colors.surface,
      child: SizedBox(
        // 36px 的放大 Logo 上下各留 15px，首像素正好在窗口 (15, 15)。
        height: 66,
        child: Row(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(left: 15),
              child: Row(
                children: <Widget>[
                  Image.asset(
                    'assets/images/plai_calendar_logo.png',
                    width: 36,
                    height: 36,
                    // 透明品牌图形随主题取前景色；浅色主题即为参考图中的黑色，
                    // 深色主题也不会因黑色图形而不可见。
                    color: colors.onSurface,
                    colorBlendMode: BlendMode.srcIn,
                    filterQuality: FilterQuality.high,
                  ),
                  const SizedBox(width: 18),
                  Text('Plai', style: logoStyle),
                ],
              ),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => _startDrag(),
                onDoubleTap: _toggleMaximize,
                child: const SizedBox.expand(),
              ),
            ),
            _WindowButton(
              tooltip: '最小化',
              icon: Icons.remove,
              onPressed: _minimize,
            ),
            _WindowButton(
              tooltip: _maximized ? '还原窗口' : '最大化',
              icon: _maximized ? Icons.filter_none : Icons.crop_square,
              onPressed: _toggleMaximize,
            ),
            _WindowButton(
              tooltip: '关闭',
              icon: Icons.close,
              close: true,
              onPressed: _close,
            ),
          ],
        ),
      ),
    );
  }
}

class _WindowButton extends StatelessWidget {
  const _WindowButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.close = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool close;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        hoverColor: close ? colors.error : colors.surfaceContainerHighest,
        child: SizedBox(
          width: 46,
          height: 36,
          child: Icon(
            icon,
            size: 18,
            color: close ? colors.onSurface : colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
