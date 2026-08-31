/// 命名路由常量表。
///
/// 所有 feature 页面统一用命名路由跳转，禁止散落字符串路由。
/// 新页面需要两处配合：本文件补路由常量，[routeRegistry] 中登记页面。
abstract final class AppRoutes {
  /// 根路由：底部导航外壳（课表 / 今日 / 设置）。
  static const String root = '/';

  /// 课表页。
  static const String timetable = '/timetable';

  /// 今日页（日程）。
  static const String today = '/today';

  /// 设置页。
  static const String settings = '/settings';

  /// 课表某周（通知点击上课提醒的深链目标）。
  ///
  /// 参数：`int` 周次（第几周）。由课表模块（plai-timetable）登记页面，
  /// 用于通知点击后定位到对应周次。未登记时通知深链会回退到根路由。
  static const String timetableWeek = '/timetable/week';

  /// 任务详情（通知点击任务提醒的深链目标）。
  ///
  /// 参数：`int` 任务主键。由日程模块（plai-schedule）登记页面，
  /// 用于通知点击后定位到对应任务。未登记时通知深链会回退到根路由。
  static const String taskDetail = '/task/detail';

  /// 国内 ROM 保活引导页（plai-notify 拥有）。
  ///
  /// 设置模块在「首次开启提醒」时导航到本页。
  static const String keepAliveGuide = '/settings/keep-alive-guide';

  /// 节次时间表编辑页（plai-settings 拥有）。
  ///
  /// 编辑各节次起止时间，支持增删节次、恢复内置默认模板。
  static const String periodsEdit = '/settings/periods';

  /// 备份与恢复页（plai-settings 拥有）。
  ///
  /// 导出 `.plai` 备份 / 从备份文件预览、合并或覆盖恢复。
  static const String backup = '/settings/backup';
}
