import 'package:flutter/widgets.dart';

/// 跨页面共用的响应式布局断点。
///
/// 1024 及以上视为桌面工作区：保留同一份业务页面，仅切换导航与内容排布。
const double kDesktopLayoutBreakpoint = 1024;

/// 由应用外壳标记当前是否正以桌面布局展示。
///
/// 页面位于侧边栏右侧后拿到的是更窄的内容约束，不能再各自按照内容宽度
/// 判断，否则刚切到桌面模式时会出现导航和页面布局不一致。
class DesktopLayoutScope extends InheritedWidget {
  const DesktopLayoutScope({
    required this.isDesktop,
    required super.child,
    super.key,
  });

  final bool isDesktop;

  static bool isDesktopOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DesktopLayoutScope>()
          ?.isDesktop ??
      MediaQuery.sizeOf(context).width >= kDesktopLayoutBreakpoint;

  @override
  bool updateShouldNotify(DesktopLayoutScope oldWidget) =>
      oldWidget.isDesktop != isDesktop;
}
