import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/app_database.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/task_repository.dart';
import '../../data/repositories/timetable_repository.dart';
import 'notification_scheduler.dart';
import 'notification_service.dart';

/// 提醒调度器 Provider。
///
/// timetable / schedule / settings 模块通过它调用调度接口（见《提醒调度接口.md》）：
/// ```dart
/// final scheduler = ref.read(notificationSchedulerProvider);
/// await scheduler.rescheduleAll();
/// ```
final notificationSchedulerProvider = Provider<NotificationScheduler>((ref) {
  return NotificationScheduler(
    TimetableRepository(AppDatabase.instance),
    TaskRepository(AppDatabase.instance),
    SettingsRepository(AppDatabase.instance),
  );
});

/// 通知服务 Provider（读取权限状态、发送测试通知等）。
final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService.instance;
});
