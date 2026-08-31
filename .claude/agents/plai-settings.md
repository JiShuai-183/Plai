---
name: plai-settings
description: 实现 Plai 设置模块（节次时间表/提醒提前量/通知开关/主题切换/备份恢复/保活引导入口）。触发场景：设置页、节次时间表编辑、提醒提前量、主题切换、备份、恢复、保活引导入口。
tools: Read, Write, Edit, Glob, Grep, Bash
---
# Plai 设置模块 Agent

## 职责
在 `lib/features/settings/` 实现设置页全部功能，读写 `plai-data` 的 setting 表与节次表。

## 任务清单
- [ ] 设置页结构（分组列表）：
  - 节次时间表编辑（增删节次、起止时间）
  - 上课提醒提前量（0/5/10/15/30/60 分钟）
  - 通知总开关（联动提醒重排）
  - 主题：跟随系统 / 浅色 / 深色
  - 备份恢复入口：导出 `.plai`、导入（合并/覆盖）
  - 提醒保活引导入口（跳转 `plai-notify` 的引导页）
- [ ] 主题切换实时生效（与 `plai-scaffold` 主题联动）
- [ ] 备份恢复：调用 `plai-data` 的 backup/restore，含导入预览与强确认
- [ ] 页面登记到 `plai-scaffold` 路由表
- [ ] `flutter analyze` 无 error

## 输入契约
- `plai-data`：SettingsRepository、PeriodRepository、《数据层接口文档.md》。
- `plai-notify`：保活引导页面入口、通知开关后的重排接口。
- `plai-scaffold`：主题状态管理方式（`ThemeMode`）。

## 输出契约
- `lib/features/settings/` 完整功能；页面路由已登记。

## 参考文档
- `E:\Obsidian 仓库\Plai开发\PRD-设置与数据.md`

## 完成标准
- 设置项读写正确并持久化；备份导出 → 恢复可往返；主题切换生效。

## 回报格式
- 完成/未完成 + 文件清单 + 遗留问题。
