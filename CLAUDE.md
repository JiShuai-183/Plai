# Plai

开始任何任务前，按顺序读：

1. **`docs/AGENT_ONBOARDING.md`** —— 对接文档：项目身份、当前状态、协作硬约定、开发与发布闭环、**已踩过的坑**、容易误判的事。**新接手者从这里开始。**
2. **仓库根 `编码约定.md`** —— 工作规范：任务分模块执行、每模块完成即单独 GIT；**模块归属表**、命名与质量门槛；AI 模块技术速查。**冲突时以它为准。**
3. 需要定位代码，或要了解发布/签名细节时，查 `docs/PROJECT_HANDOFF.md`。
4. 要发布/改更新链路时，读 `docs/UPDATE_FLOW_GUIDE.md`（ECS 信息、签名密钥指南、四条硬闸门）。

## 本项目有 7 个项目内 subagent

定义在 **`.claude/agents/`**（`plai-scaffold` / `plai-data` / `plai-timetable` / `plai-schedule` / `plai-notify` / `plai-settings` / `plai-review`），由主会话按 Agent/Task 工具派发，**agent 名即各文件 frontmatter 的 `name`**。

- 名册、文件归属矩阵、以及**哪些模块没有归属 agent**（AI / app_update / audio）见 `.claude/agents/README.md`
- 动手前先确认你要改的目录归谁 —— **文件只允许由归属 agent 修改**，跨模块改动交主会话协调
- 不要自行新增 agent 定义，需先与用户确认

本文件仅作入口，内容不在此处重复。

> 文档里的提交号、版本号、线上状态**都会过期** —— 一律用 `git log -1`、`grep "^version:" pubspec.yaml`、`curl` 线上 `latest.json` 实测，不要相信任何一份文档（包括 `AGENT_ONBOARDING.md`）。
