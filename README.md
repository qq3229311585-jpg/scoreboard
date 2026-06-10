# 记分器 · iOS + Apple Watch

面向日常比赛场景的记分工具，iPhone 与 Apple Watch 深度联动：手表可独立开赛，手机实时同步比分、心率与赛后数据。

## 功能

- **多项目支持**：羽毛球、乒乓球、网球、篮球
- **Watch 独立记分**：无需手机也可完整开始、记分、结束一场比赛
- **三层实时同步**：sendMessage 实时 / applicationContext 快照 / transferUserInfo 保证送达
- **心率记录**：Watch 端全程 HealthKit 采集，赛后在手机上查看心率曲线
- **逐分事件流**：记录每一分的时间、间隔、累计比分，支持完整赛后回溯
- **历史记录与对阵统计**：自动保存，支持筛选、搜索、详情查看
- **数据导出 / 导入**：单场导出、全量备份，支持 Mac 端同步导入

## 技术栈

- **iOS**：Capacitor 8 + HTML/JS（`mobile-web/`）
- **watchOS**：纯 SwiftUI + WatchConnectivity + HealthKit
- **通信**：WCSession 三层模型（手机 ↔ 手表双向）

## 开发环境

- Xcode 16+
- iOS 17+ / watchOS 10+

## 构建

```bash
# 1. 安装依赖
npm install

# 2. 修改 web 端后同步到 iOS
npx cap sync ios

# 3. 用 Xcode 打开工程
open ios/App/App.xcodeproj
```

## 相关仓库

- [scoreboard-web](https://github.com/qq3229311585-jpg/scoreboard-web) — Web / Mac / Android 版本

