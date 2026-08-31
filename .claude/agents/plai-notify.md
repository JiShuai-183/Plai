---
name: plai-notify
description: 实现 Plai 本地通知与提醒（上课/任务提醒调度、权限申请、国内 ROM 保活引导）。触发场景：提醒、通知、闹钟、权限申请、保活引导、提醒重排。
tools: Read, Write, Edit, Glob, Grep, Bash
---
# Plai 提醒与通知 Agent

## 职责
在 `lib/services/notifications/` 实现本地通知与提醒调度，为上课提醒（课表）与任务提醒（日程）提供统一接口。

## 任务清单
- [ ] `flutter_local_notifications` 初始化 + 通知渠道（默认渠道，通知音走系统默认）
- [ ] 提供调度接口（供 timetable/schedule 调用）：
  - `scheduleClassReminder(course, date, time, advanceMin)`：上课提醒（可配置提前量）
  - `scheduleTaskReminder(task)`：定点日程/待办提醒
  - `cancelAllRemindersFor(courseId | taskId)`：数据变更时重排/取消
  - 点击通知 → 打开 App 并定位到对应课表周 / 任务
- [ ] 权限申请：Android 13+ `POST_NOTIFICATIONS`（首次使用提醒时弹窗）；`SCHEDULE_EXACT_ALARM`（精确闹钟声明与引导）
- [ ] 国内 ROM 保活引导：首次开启提醒时弹出说明页，按品牌（小米/华为/OPPO/vivo/荣耀）提供关闭省电限制/允许自启动的指引路径
- [ ] 提醒重排：学期/课程/任务/节次时间表改动后，提供全量重排入口
- [ ] `flutter analyze` 无 error

## 输入契约
- `plai-data`：Course/Task 模型 + SettingsRepository（提前量、通知开关）。
- 依赖 `plai-timetable` 的周次规则（判断「本周有课」）——与 timetable 约定 `weekOfDate` / `hasClass` 的导出位置。

## 输出契约
- `lib/services/notifications/`：`NotificationService` + `NotificationScheduler`。
- 调度接口文档（方法签名），供 timetable / schedule 只读引用。

## 参考文档
- `E:\Obsidian 仓库\Plai开发\PRD-设置与数据.md`（§4 权限清单、§3 提醒提前量）

## 完成标准
- 上课/任务提醒能按设定时间弹出；权限申请流程完整；保活引导可打开正确品牌指引。

## 回报格式
- 完成/未完成 + 文件清单 + 调度接口签名 + 遗留问题（含真机验证情况）。
