# AGENTS.md — Scoreboard

## 1. 接手前必读（共享工作区）

接手任何实质性工作前，按顺序读以下文件：

1. `/Users/secondcomputer/Documents/AI-Shared/Projects/scoreboard/PROJECT_PROFILE.md` — 项目概览、技术栈、运行目标
2. `/Users/secondcomputer/Documents/AI-Shared/Projects/scoreboard/STRUCTURE.md` — 目录结构与数据流
3. `/Users/secondcomputer/Documents/AI-Shared/Projects/scoreboard/PROJECT_RULES.md` — 编辑规则与边界
4. `/Users/secondcomputer/Documents/AI-Shared/Projects/scoreboard/CURRENT_TASK.md` — 当前任务与已知 bug
5. `/Users/secondcomputer/Documents/AI-Shared/Projects/scoreboard/HANDOFF.md` — 交接要点与风险
6. `/Users/secondcomputer/Documents/AI-Shared/Projects/scoreboard/KEY_FILES.md` — 关键文件速查

共享工作区用于：跨 Agent 任务状态、项目结构说明、决策历史、验证摘要。

## 2. 项目简介

`scoreboard` 是一个混合架构的运动记分 App，覆盖 macOS 桌面（Electron）、iOS、Android 和 Apple Watch。

- **Web 层**：`index.html` / `mobile-web/index.html`（Capacitor 桥接）
- **纯 JS 逻辑**：`src/core.js`
- **iPhone 原生桥**：`ios/App/App/`（WatchPlugin、HealthKitPlugin）
- **Watch App**：`ios/App/WatchApp/`（WatchMatchManager、PhoneSessionManager、WorkoutManager）
- **Android**：`android/`（Capacitor 自动生成）

## 3. 关键约定

### Web → iOS 同步

修改 `mobile-web/index.html` 后**必须**跑：

```
node scripts/prepare-mobile-web.mjs && npx cap sync ios
```

否则真机运行的是旧 bundle。这是最常见的"改了没生效"陷阱。

### 构建与测试

| 目标 | 命令 |
|------|------|
| JS 单测 | `npm test` |
| iOS 构建 | `xcodebuild -project ios/App/App.xcodeproj -scheme App -destination 'generic/platform=iOS' build` |
| Watch 构建 | `xcodebuild -project ios/App/App.xcodeproj -scheme "Scoreboard Watch App" -destination 'generic/platform=watchOS' build` |
| 安装到真机 | `xcrun devicectl device install app --device <udid> <path>.app` |

### 代码边界

- 业务逻辑 → `src/core.js`，不要混入 UI 文件
- iPhone ↔ Watch 同步 → `WatchPlugin.swift` / `WatchMatchManager.swift`
- HealthKit → `HealthKitPlugin.swift` / `WorkoutManager.swift`
- 最小化改动，改前先确认是否已有实现

## 4. MCP 工具（.mcp.json）

| 工具 | 状态 | 用途 |
|------|------|------|
| **Context7** | 已启用 | 查询框架/库最新官方文档（`npx @upstash/context7-mcp`） |
| **Serena** | 待激活 | 项目复杂度提升后启用；提供语义化代码索引；命令行工具需先安装 |

## 5. Superpowers（Qoder 内置）

Qoder IDE 内置代码库理解能力（符号搜索、语义搜索、RepoWiki），无需额外安装。

`docs/superpowers/` 用于存放 AI 生成的文档：

- `docs/superpowers/specs/` — 功能规格
- `docs/superpowers/plans/` — 实施计划

## 6. 本地语义索引

- `.serena/` — Serena 语义索引目录（Serena 激活后自动维护）
