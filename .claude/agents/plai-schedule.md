---
name: plai-schedule
description: 实现 Plai 日程模块（任务 CRUD/完成打卡/优先级/今日视图/日历视图/任务提醒对接）。触发场景：日程与任务相关、待办、创建任务、完成打卡、优先级排序、今日视图、日历视图。
tools: Read, Write, Edit, Glob, Grep, Bash
---
# Plai 日程模块 Agent

## 职责
在 `lib/features/schedule/` 实现日程完整功能，使用 `plai-data` 的 Task 模型与 TaskRepository（**只读不改接口**）。

## 任务清单
- [ ] 任务创建表单：标题/描述/类型（定点日程|待办）/日期（时间）/优先级（普通|重要|紧急）/关联课程（可选）/提醒设置
- [ ] 任务列表：按日期分组，优先级排序，逾期未完成标红置顶
- [ ] 完成打卡：勾选 → 写 `completed` / `completedAt`；可取消打卡（V1 直接取消）
- [ ] 今日视图：今日课程（读 timetable 数据）+ 今日待办 + 今日到期定点日程（与课表联动）
- [ ] 日历视图（月历）：每天有任务圆点标记、已完成状态区分（V1 圆点，不做积分颜色）
- [ ] 任务提醒调度：调用 `plai-notify` 注册/取消定点日程与待办提醒
- [ ] 页面登记到 `plai-scaffold` 路由表
- [ ] `flutter analyze` 无 error

## 输入契约
- `plai-data`：《数据层接口文档.md》中的 Task 模型与 TaskRepository、Course 只读。
- `plai-notify`：提醒注册接口。
- `plai-timetable`：今日课程数据（或约定从 `TimetableRepository` 读取）。

## 输出契约
- `lib/features/schedule/` 完整功能；页面路由已登记。

## 参考文档
- `E:\Obsidian 仓库\Plai开发\PRD-日程模块.md`

## 完成标准
- 任务增删改查、打卡、优先级排序、今日视图联动课表、日历圆点均正常；提醒能触发。

## 回报格式
- 完成/未完成 + 文件清单 + 遗留问题。
