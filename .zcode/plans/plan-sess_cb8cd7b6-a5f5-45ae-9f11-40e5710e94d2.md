# 提醒/反馈增强批次：提醒震动 ×2 + 每日打卡提醒时间 + 完成提示音

## 功能一：课程提醒震动 / 日程提醒震动（总设置，默认不震动）

技术约束：Android 通知渠道创建后震动属性不可改 → **渠道双轨**：
- 渠道 `plai_reminders`（enableVibration: **false**）+ 新渠道 `plai_reminders_vib`（true）
- notification_service.initialize：先 deleteChannel 清理旧渠道（老安装的渠道已是震动=true，必须删掉重建），再创建两个新渠道
- 设置键（NotificationSettingsKeys）：`notify.class_vibrate` / `notify.task_vibrate`，默认 'false'

改动：
- `_schedule` 增加 channelId 参数；`scheduleClassReminder` / `scheduleTaskReminder` 增加 `bool? vibrate`（null=内部读设置；批量路径读一次传入避免逐条查库）；rescheduleAll/rescheduleTimetableReminders 读取并传参
- settings_page「提醒」区加两个 SwitchListTile（即时保存 + 触发 rescheduleAll 重排换渠道）——沿用现有即时保存模式

## 功能二：每日打卡提醒时间（db V4）

- task 表加列 `daily_remind_time TEXT`（'HH:mm' 可空），dbVersion 3→4，onUpgrade 沿用 _hasColumn 加列模式；Task 模型 dailyRemindTime（构造/copyWith/toDb/fromDb）
- task_form_page：daily 类型显示「每日提醒时刻」ListTile（showPlaiTimePicker，可清除）
- 调度：scheduleTaskReminder 对 daily+remindTime → `zonedSchedule(matchDateTimeComponents: DateTimeComponents.time)`（一条通知每日同一时刻重复，ID=taskReminderId(taskId)，删除/清空提醒即取消）；渠道按「日程提醒震动」开关
- 测试：V3→V4 迁移（照 task_migration_test 模式）；daily 每日重复调度用例（FakeNotificationService 捕获）

## 功能三：日程完成提示音（本地音频，总设置选择）

- pubspec 新增 `audioplayers`；键 `notify.complete_sound`（默认 '' = 不播）
- 新建 `lib/services/audio/complete_sound.dart`：CompleteSoundPlayer（单例 AudioPlayer 播 DeviceFileSource）+ `playCompletionSound(ref)` helper（读设置→播，全 try-catch 静默）
- 播放点：toggleTaskCompleted 完成翻转时、AI 写工具 set_task_completed 完成时、每日打卡勾选时
- settings_page 新 ListTile「日程完成提示音」：FilePicker（audio 类型）选文件 → **复制到应用文档目录固定文件名**（避免源文件移动失效）→ 存键；已设置显示文件名 + 清除按钮
- 测试：完成翻转触发播放（注入假播放器）；AI set_task_completed 路径同样触发

## 提交切分（3 个独立提交，全部完成后统一停下验收）
1. `V1.1: 提醒-课程/日程提醒震动开关（渠道双轨/设置页）`
2. `V1.1: 日程-每日打卡提醒时间（dbV4迁移/表单时刻选择/每日重复调度）`
3. `V1.1: 日程-完成提示音（audioplayers/本地音频选择复制/完成与打卡触发）`

## 验收注意
- 功能一改渠道定义 → 需重新编译安装（重装后旧渠道自动清理重建）
- 每日打卡提醒依赖系统的精确闹钟/通知权限（已有）
- 完成提示音仅在「总设置」选择了音频文件后生效，默认静音