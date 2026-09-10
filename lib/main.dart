import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'routes/app_routes.dart';
import 'routes/route_registry.dart';
import 'services/notifications/navigator.dart';
import 'services/notifications/notification_service.dart';
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
    // 主题跟随设置模块的控制器实时生效（跟随系统 / 浅色 / 白色 / 深色）。
    final PlaiThemeMode mode = ref.watch(themeModeProvider);
    // 只有显式选「浅色」才用绿色品牌亮色；「白色」与「跟随系统」的亮色侧
    // 都用纯白底 + 中性灰（system 在系统为暗时走 darkTheme，不受此影响）。
    final ThemeData lightTheme =
        mode == PlaiThemeMode.light ? PlaiTheme.light() : PlaiTheme.white();
    final ThemeMode materialMode = switch (mode) {
      PlaiThemeMode.system => ThemeMode.system,
      PlaiThemeMode.light || PlaiThemeMode.white => ThemeMode.light,
      PlaiThemeMode.dark => ThemeMode.dark,
    };
    return MaterialApp(
      title: 'Plai',
      debugShowCheckedModeBanner: false,
      // 全局导航 key：通知点击深链在任意时刻通过它拿到 Navigator。
      navigatorKey: appNavigatorKey,
      theme: lightTheme,
      darkTheme: PlaiTheme.dark(),
      themeMode: materialMode,
      routes: routeRegistry,
      initialRoute: AppRoutes.root,
    );
  }
}
