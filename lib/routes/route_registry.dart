import 'package:flutter/material.dart';

import '../app_shell.dart';
import '../features/schedule/schedule_page.dart';
import '../features/schedule/task_detail_page.dart';
import '../features/settings/backup_page.dart';
import '../features/settings/periods_edit_page.dart';
import '../features/settings/settings_page.dart';
import '../features/settings/timetable_settings_page.dart';
import '../features/timetable/timetable_page.dart';
import '../features/timetable/timetable_week_page.dart';
import '../services/notifications/keep_alive_guide_page.dart';
import 'app_routes.dart';

/// 页面构造器：由路由名构造页面。
typedef RoutePageBuilder = Widget Function(BuildContext);

/// feature 页面登记入口。
///
/// 后续 feature agent 完成各自页面后，把「路由常量 → 页面构造器」登记进本表，
/// 即可通过 [AppRoutes] 中的命名路由跳转。当前登记：
/// - [AppRoutes.root] → [AppShell]（底部导航外壳）
/// - [AppRoutes.timetable] → [TimetablePage]
/// - [AppRoutes.today] → [SchedulePage]
/// - [AppRoutes.settings] → [SettingsPage]
/// - [AppRoutes.keepAliveGuide] → [KeepAliveGuidePage]（plai-notify 拥有）
/// - [AppRoutes.periodsEdit] → [PeriodsEditPage]（plai-settings 拥有）
/// - [AppRoutes.timetableSettings] → [TimetableSettingsPage]（plai-settings 拥有）
/// - [AppRoutes.backup] → [BackupPage]（plai-settings 拥有）
///
/// 登记说明：
/// - [AppRoutes.taskDetail] → 任务详情页（plai-schedule，参数 int 任务 id）
final Map<String, RoutePageBuilder> routeRegistry = {
  AppRoutes.root: (_) => const AppShell(),
  AppRoutes.timetable: (_) => const TimetablePage(),
  AppRoutes.today: (_) => const SchedulePage(),
  AppRoutes.settings: (_) => const SettingsPage(),
  AppRoutes.keepAliveGuide: (_) => const KeepAliveGuidePage(),
  AppRoutes.periodsEdit: (_) => const PeriodsEditPage(),
  AppRoutes.timetableSettings: (_) => const TimetableSettingsPage(),
  AppRoutes.backup: (_) => const BackupPage(),
  AppRoutes.timetableWeek: (_) => const TimetableWeekPage(),
  AppRoutes.taskDetail: (_) => const TaskDetailPage(),
};
