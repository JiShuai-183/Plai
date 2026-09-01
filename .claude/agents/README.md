# Plai V1 子 Agent 协作说明

Plai 的 V1 实现拆为 7 个子 agent，由主会话（总协调者）按阶段逐个派发。每个 agent 一次只接一个有边界的任务，完成后回报，主会话接手，保持主上下文轻量。

## 7 个 Agent 一览

| agent | 职责 | 调度阶段 |
|---|---|---|
| `plai-scaffold` | 工程骨架：目录/依赖/主题/导航/路由/编码约定 | Phase 1 |
| `plai-data` | 数据层：schema/模型/Repository/备份/导入导出 + 接口文档 | Phase 2 |
| `plai-timetable` | 课表：学期/课程/周次规则/节次/周日视图/导入导出 | Phase 3 |
| `plai-schedule` | 日程：任务/打卡/优先级/今日视图/日历视图 | Phase 3 |
| `plai-notify` | 提醒：通知/调度/权限/ROM 保活引导 | Phase 3 |
| `plai-settings` | 设置：节次表/提醒提前量/主题/备份恢复/保活入口 | Phase 3 |
| `plai-review` | 集成评审：一致性/联调/测试/构建验证 | Phase 4 |

> V2（积分激励 / AI / Windows 桌面版）的 agent 到 V2 阶段再建。

## 调度阶段

1. **Phase 1**：装 Flutter → `plai-scaffold` 初始化骨架
2. **Phase 2**：`plai-data` 定模型与 Repository 接口
3. **Phase 3**：`plai-timetable` / `plai-schedule` / `plai-notify` / `plai-settings`（依赖 data 契约；建议顺序执行避免文件冲突，或按明确文件归属小批量并行）
4. **Phase 4**：`plai-review` 集成验收

## 接口契约（防 agent 间打架）

- **目录结构**：scaffold 定（`lib/data` / `lib/features/<模块>` / `lib/services` / `lib/theme` / `lib/routes`）。
- **领域模型 / Repository**：data 定，feature agent **只读不改**，通过《数据层接口文档.md》对齐。
- **路由**：scaffold 定路由表，feature 只登记页面。
- **提醒调度接口**：notify 定签名，timetable / schedule 调用。
- 每个 agent 完成后回报：结构化格式（见下「沟通规则」）。

## 沟通规则（caveman，主会话与所有 agent 一律遵守）

- **Caveman 全程**：电报式极简表达，省词省句，不客套。
- **机器可读回报**：agent 间 / 回主会话用紧凑结构化格式（JSON / 键值对 / 清单），不用自然语言长段陈述，省上下文省 token。
- **不懂就问**：需求 / 接口 / 任务边界不明确时，先向主会话（或用户）提问确认，听懂再动手；不猜测硬做。

## 参考 PRD

`E:\Obsidian 仓库\Plai开发\` 下：PRD-总览 / 课表模块 / 日程模块 / 积分激励(V2) / AI模块(V2) / 设置与数据。

## 编码约定

阅读工程根目录《编码约定.md》（`plai-scaffold` 产出）后再动手。
