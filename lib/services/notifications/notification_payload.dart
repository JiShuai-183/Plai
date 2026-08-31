import 'dart:convert';

/// 通知点击意图类型。
enum NotificationIntentType {
  /// 点击上课提醒 → 定位课表某周。
  classReminder,

  /// 点击任务提醒 → 定位任务详情。
  taskReminder,
}

/// 通知点击意图：描述「要打开哪个页面」。
///
/// 由 payload 解析而来，路由分发时据此决定跳转目标：
/// - 上课提醒 → [AppRoutes.timetableWeek]，参数为 [week]（int 周次）
/// - 任务提醒 → [AppRoutes.taskDetail]，参数为 [taskId]（int 任务主键）
class NotificationIntent {
  const NotificationIntent({
    required this.type,
    this.courseId,
    this.week,
    this.taskId,
  });

  final NotificationIntentType type;

  /// 上课提醒的课程主键。
  final int? courseId;

  /// 上课提醒的周次。
  final int? week;

  /// 任务提醒的任务主键。
  final int? taskId;
}

/// 通知 payload 编解码：随通知持久化的深链路由信息。
///
/// payload 为 JSON 字符串，编码规则固定，供其他模块调用方
/// 与 [NotificationService] 深链分发使用。
abstract final class NotificationPayload {
  /// 构造上课提醒 payload。
  static String classReminder(int courseId, int week) => jsonEncode({
        'type': 'class',
        'courseId': courseId,
        'week': week,
      });

  /// 构造任务提醒 payload。
  static String taskReminder(int taskId) => jsonEncode({
        'type': 'task',
        'taskId': taskId,
      });

  /// 解析 payload；无法识别返回 null。
  static NotificationIntent? parse(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final map = jsonDecode(payload);
      if (map is! Map<String, dynamic>) return null;
      switch (map['type']) {
        case 'class':
          final int? courseId = map['courseId'] as int?;
          final int? week = map['week'] as int?;
          if (courseId == null || week == null) return null;
          return NotificationIntent(
            type: NotificationIntentType.classReminder,
            courseId: courseId,
            week: week,
          );
        case 'task':
          final int? taskId = map['taskId'] as int?;
          if (taskId == null) return null;
          return NotificationIntent(
            type: NotificationIntentType.taskReminder,
            taskId: taskId,
          );
      }
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
    return null;
  }
}
