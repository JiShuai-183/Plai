/// 通知 ID 与通知渠道常量。
///
/// ID 分区设计（Android 通知 ID 为 32 位有符号 int）：
/// - 上课提醒：`1_000_000 + courseId*128 + week`，每个课程每周一个，互不覆盖；
///   `week` 约定 1–99（周期上限，PRD 约束），编码进低 7 位。
/// - 任务提醒：`2_000_000 + taskId`，每个任务一个。
///
/// 同一「课程+周」/「任务」重复调度时使用相同 ID，新通知会覆盖旧的，
/// 天然实现「数据变更后重排」。
abstract final class NotificationIds {
  /// 默认通知渠道 id（系统默认提示音）。
  static const String defaultChannelId = 'plai_reminders';

  /// 默认通知渠道名称。
  static const String defaultChannelName = '上课与任务提醒';

  /// 默认通知渠道描述。
  static const String defaultChannelDescription = 'Plai 的上课与任务提醒';

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
