import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
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

/// 全局中文 locale。
///
/// 本 App 全部界面文案都是硬编码中文，是**单语言应用**。这里显式写死
/// `zh_CN`（而不是跟随 `Locale.system`），是为了避免设备语言非中文时出现
/// 「半边中文半边英文」的错配 —— 自研文案仍显示中文，而 Material 内置文案
/// （日期选择器月份/星期表头、对话框默认按钮、返回按钮 tooltip 等）会随
/// 系统语言回落成英文。
const Locale appLocale = Locale('zh', 'CN');

/// App 支持的语言（仅中文）。抽成顶层常量，测试可复用同一份配置。
const List<Locale> appSupportedLocales = <Locale>[appLocale];

/// 全局本地化委托：Material / Widgets / Cupertino 三件套。
///
/// 缺任一委托时对应组件会回落到默认英文（`showDatePicker` 的日历卡正是
/// 依赖 Material 委托）。抽成顶层常量供测试复用，避免生产与测试配置漂移。
const List<LocalizationsDelegate<dynamic>> appLocalizationsDelegates =
    <LocalizationsDelegate<dynamic>>[
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

/// Plai 应用根组件。
class PlaiApp extends ConsumerWidget {
  const PlaiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 主题跟随设置模块的控制器实时生效（跟随系统 / 浅色 / 白色 / 深色）。
    final PlaiThemeMode mode = ref.watch(themeModeProvider);
    // 只有显式选「浅色」才用绿色品牌亮色；「白色」与「跟随系统」的亮色侧
    // 都用纯白底 + 中性灰（system 在系统为暗时走 darkTheme，不受此影响）。
    final ThemeData lightTheme = mode == PlaiThemeMode.light
        ? PlaiTheme.light()
        : PlaiTheme.white();
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
      // 中文单语言：显式 locale + 仅 zh_CN + 三件套委托，让 Flutter
      // 内置组件（日期选择器等）显示中文。详见 [appLocale] 注释。
      locale: appLocale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: appLocalizationsDelegates,
      routes: routeRegistry,
      initialRoute: AppRoutes.root,
    );
  }
}
