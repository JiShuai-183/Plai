import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/backup/backup_service.dart';
import '../../data/db/app_database.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/task_repository.dart';
import '../../data/repositories/timetable_repository.dart';

/// 设置域 Repository Provider（设置页 / 主题控制器共用）。
///
/// 归属 plai-settings；`lib/theme/theme_controller.dart` 经它持久化主题。
final settingsRepositoryProvider = Provider<ISettingsRepository>((ref) {
  return SettingsRepository(AppDatabase.instance);
});

/// 课表域 Repository Provider（本模块用它读写节次时间表）。
///
/// 数据层把节次（Period）的 CRUD 收在 [ITimetableRepository] 上
/// （见《数据层接口文档.md》§5.1），这里单独命名避免与课表模块未来的
/// `timetableRepositoryProvider` 冲突。
final settingsTimetableRepoProvider = Provider<ITimetableRepository>((ref) {
  return TimetableRepository(AppDatabase.instance);
});

/// 任务域 Repository Provider（备份服务导出任务需要读取）。
final settingsTaskRepoProvider = Provider<ITaskRepository>((ref) {
  return TaskRepository(AppDatabase.instance);
});

/// 备份 / 恢复服务 Provider（导出 `.plai` / 导入预览 / 恢复）。
final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(
    db: AppDatabase.instance,
    timetable: ref.watch(settingsTimetableRepoProvider),
    tasks: ref.watch(settingsTaskRepoProvider),
    settings: ref.watch(settingsRepositoryProvider),
  );
});
