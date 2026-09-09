import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/db/database_factory_setup.dart';
import 'routes/app_routes.dart';
import 'routes/route_registry.dart';
import 'services/notifications/navigator.dart';
import 'services/notifications/notification_service.dart';
import 'theme/theme.dart';
import 'theme/theme_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  configureDatabaseFactoryForCurrentPlatform();
  // 预初始化本地通知（注册开机恢复接收器、创建默认渠道、解析冷启动深链）。
  // 不 await：不阻塞首帧；深链在首帧后由服务自行分发。
  unawaited(NotificationService.instance.initialize());
  runApp(const ProviderScope(child: PlaiApp()));
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
    );
  }
}
