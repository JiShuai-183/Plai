import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'routes/app_routes.dart';
import 'routes/route_registry.dart';
import 'services/notifications/navigator.dart';
import 'services/notifications/notification_service.dart';
import 'shared/splash_overlay.dart';
import 'theme/theme.dart';
import 'theme/theme_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: PlaiApp()));
  // 首帧渲染后再初始化本地通知（注册开机恢复接收器、创建默认渠道、解析
  // 冷启动深链）。initialize() 内含同步的时区表构造，放在 runApp 之前会
  // 推迟首帧；放到 postFrame 后首帧不受其影响。
  // 深链本就需 Navigator 就绪，调度器各入口也会 await 同一份初始化 Future，
  // 故延后不引入竞态。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(NotificationService.instance.initialize());
  });
}

/// Plai 应用根组件。
class PlaiApp extends ConsumerWidget {
  const PlaiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'Plai',
      debugShowCheckedModeBanner: false,
      // 全局导航 key：通知点击深链在任意时刻通过它拿到 Navigator。
      navigatorKey: appNavigatorKey,
      theme: PlaiTheme.light(),
      darkTheme: PlaiTheme.dark(),
      // 主题跟随设置模块的控制器实时生效（跟随系统 / 浅色 / 深色）。
      themeMode: ref.watch(themeModeProvider),
      routes: routeRegistry,
      initialRoute: AppRoutes.root,
      // 开屏叠在整个 Navigator 之上（含后续 push 的页面）；消退后自身
      // 收缩为 0 尺寸并不再拦截触摸。
      builder: (BuildContext context, Widget? child) => Stack(
        children: <Widget>[
          ?child,
          const SplashOverlay(),
        ],
      ),
    );
  }
}
