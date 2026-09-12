/// 通知 ID 与通知渠道常量。
///
/// ID 分区设计（Android 通知 ID 为 32 位有符号 int）：
/// - 上课提醒：`1_000_000 + courseId*128 + week`，每个课程每周一个，互不覆盖；
///   `week` 约定 1–99（周期上限，PRD 约束），编码进低 7 位。
/// - 任务提醒：`2_000_000 + taskId`，每个任务一个。
///
/// 同一「课程+周」/「任务」重复调度时使用相同 ID，新通知会覆盖旧的，
/// 天然实现「数据变更后重排」。
///
/// 渠道按**内容**划分：[classChannelId]（课表提醒）与 [taskChannelId]
/// （日程提醒）。调度时按提醒类型选渠道，用户就能在系统设置里按「课表 /
/// 日程」分别管理各自的声音、震动、重要度。
///
/// **历史（勿抹）**：本模块曾按「震不震动」拆渠道 —— 两个渠道
/// `plai_reminders`（不震）与 `plai_reminders_vib`（震），配 App 内「课程提醒
/// 震动 / 日程提醒震动」两个开关，调度时按开关选渠道。该划分已废弃：这两个
/// 渠道各自同时承载课表和日程提醒，渠道名（「上课与任务提醒」）反映不出内容，
/// 用户看系统设置看不懂；而震动本就是渠道级属性，系统设置里已能按渠道分别
/// 控制，App 内再放一个开关纯属重复。故改为按内容拆，App 内两个震动开关已移除。
///
/// **删除渠道的副作用（有意依赖）**：删除某渠道会一并清掉该渠道上已调度 /
/// 已展示的通知，故换渠道时旧提醒不会自动迁移。本模块依赖「App 冷启动必执行
/// `rescheduleAll()`」（见 `app_shell.dart` 的启动重排）把它们重排到新渠道；
/// 若去掉该重排，必须同步补上渠道迁移逻辑。
abstract final class NotificationIds {
  /// 课表提醒渠道 id（承载上课提醒）。
  static const String classChannelId = 'plai_class_reminders';

  /// 课表提醒渠道名称。
  static const String classChannelName = '课表提醒';

  /// 课表提醒渠道描述。
  static const String classChannelDescription = 'Plai 的课表提醒（上课前提醒）';

  /// 日程提醒渠道 id（承载日程 / 待办 / 每日打卡提醒）。
  static const String taskChannelId = 'plai_task_reminders';

  /// 日程提醒渠道名称。
  static const String taskChannelName = '日程提醒';

  /// 日程提醒渠道描述。
  static const String taskChannelDescription = 'Plai 的日程提醒（日程 / 待办 / 每日打卡）';

  /// 渠道 id →（名称, 描述）。
  ///
  /// 构建通知详情时按 [channelId] 解析展示元数据，避免两处渠道名写死在分支里。
  /// 未知 id 回落到课表渠道（当前只有两条渠道，调用方均为本模块内部）。
  static ({String name, String description}) channelMetaOf(String channelId) =>
      switch (channelId) {
        taskChannelId => (
            name: taskChannelName,
            description: taskChannelDescription,
          ),
        _ => (
            name: classChannelName,
            description: classChannelDescription,
          ),
      };

  /// 上课提醒 ID 分区基准。
  static const int _classIdBase = 1000000;

  /// 任务提醒 ID 分区基准。
  static const int _taskIdBase = 2000000;

  /// 上课提醒通知 ID（[courseId] 主键 + [week] 周次）。
  static int classReminderId(int courseId, int week) =>
      _classIdBase + courseId * 128 + (week & 0x7F);

  /// 任务提醒通知 ID（[taskId] 主键）。
  static int taskReminderId(int taskId) => _taskIdBase + taskId;
}
