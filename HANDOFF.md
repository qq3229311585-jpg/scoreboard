# 记分器 App — Codex 工作交接文档
> 当前版本：Android 1.2.1 / Mac 1.2.0  
> 交接时间：2026-06-06  
> 主文件：`/Users/secondcomputer/scoreboard/index.html`（2933 行，单文件全量实现）

---

## 一、项目结构

```
scoreboard/
├── index.html          ← 唯一的业务文件，所有 HTML/CSS/JS 在此
├── main.js             ← Electron 主进程（极简，只开窗口加载 index.html）
├── package.json        ← electron-builder 配置；scripts: build:dmg / prepare:mobile
├── mobile-web/         ← prepare:mobile 脚本自动生成，是 Capacitor 的 webDir
├── android/            ← Capacitor Android 工程
│   └── app/src/main/java/com/scoreboard/app/MainActivity.java
└── dist/               ← electron-builder 输出目录（DMG 在这里）
```

### 构建命令

```bash
# 1. 同步 web 资源到 Android
npm run prepare:mobile && npx cap sync android

# 2. 打 Release APK（需要 JDK 21，不能用 JDK 26）
cd android
JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
  ./gradlew assembleRelease
# 输出：android/app/build/outputs/apk/release/app-release.apk

# 3. 打 Mac DMG
npm run build:dmg
# 输出：dist/记分器-x.x.x-arm64.dmg
```

APK 历史输出目录：`/Users/secondcomputer/Documents/Codex/2026-06-06/claude-code/outputs/`

---

## 二、技术架构要点

### 平台检测
```javascript
const APP_PLATFORM = (() => {
  if (navigator.userAgent.includes('Android')) return 'android';
  if (navigator.userAgent.includes('Electron'))  return 'desktop';
  return 'web';
})();
document.documentElement.dataset.platform = APP_PLATFORM;
// CSS 用 html[data-platform="android"] 区分平台样式
```

### 状态模型
- 全局 `S`（当前比赛状态）和 `H`（undo 历史栈，每次得分前 push）
- `CFG`（比赛配置：sport / ptWin / totalSets / names）
- 历史记录存 `localStorage` key = `sb_history`，最多 200 条

### 导航系统
- `navTo(screenName, dir?)` 控制所有页面切换
- `navStack[]` 记录返回栈（Android 系统返回键走 `handleAndroidBack()`）
- 页面 ID：`homeScreen` / `setupScreen` / `gameScreen` / `historyScreen` / `detailScreen` / `settingsScreen`

### Android 安全区域
- `MainActivity.java` 通过 `ViewCompat.setOnApplyWindowInsetsListener` 注入 CSS 变量
- `--safe-top` / `--safe-bottom` / `--safe-left` / `--safe-right`（单位 px）
- Edge-to-edge 模式开启：`WindowCompat.setDecorFitsSystemWindows(false)`

### 原生文件保存桥（Android）
- `MainActivity.java` 中的 `ScoreboardBridge` 内部类，`@JavascriptInterface` 暴露给 JS
- JS 调用：`window.ScoreboardBridge.saveToDownloads(filename, jsonString)` → 返回 `"ok"` 或 `"error:..."`
- Android 10+：MediaStore API；Android 9 及以下：直接写 Downloads 目录
- **必须在 `super.onCreate()` 之后、页面加载前注册**（当前代码已正确）

---

## 三、本次 session 完成的功能

### 历史记录分析（全部完成）
1. **跨场统计卡**：胜率、总场次、局均分、最长连胜
2. **双线走势图**：SVG 绘制，每局累计得分折线，局间分界线
3. **分段得分**：把每局按 5 分一段切分，显示双方各阶段得分柱状
4. **关键球分析**：统计赛点/局点转换率、Break Point
5. **节奏分析**：平均点时长、最快/最慢点、长回合占比

### 历史页 UI
- 两个 Tab：全部记录 / 对阵统计（按姓名对分组，显示胜负记录）
- Android 端：左滑显示删除按钮（微信/Twitter 风格，`left:100%` 方案）
- 汇总卡（总场次/胜率/最多运动）
- 8 条 Demo 演示数据（首次无记录时自动注入，用确定性伪随机生成）

### 比赛功能
- **篮球**：+1/+2/+3 大按钮；菜单「下一节」推进节次；节次显示在比分区
- **运动规则提示**：已从设置页**隐藏**（用户要求），JS 逻辑保留但 CSS `display:none`
- **设置页 Android 布局**：2 列 Grid（左列队名+规则，右列运动图标 2×2），无运动提示

### 数据导出/导入
- **Android 导出**：优先写入手机 Downloads 文件夹（原生桥），成功后底部绿色 Toast；失败降级为剪贴板+模态框
- **Mac 导出**：标准 blob 下载（`.json` 文件）
- **Mac 导入**：设置页文件选择器，支持合并去重；Android 隐藏此入口
- 导出格式：结构化 JSON，含 `matches[]` 每场比赛的逐球事件、统计摘要，适合 AI 分析

### Mac DMG
- `npm run build:dmg` 一键生成（electron-builder 已配置好）
- 输出：`dist/记分器-1.2.0-arm64.dmg`（118MB，无签名，首次打开需在安全设置里允许）

---

## 四、当前已知问题 / 未完成项

### ⚠️ 滑动删除卡片宽度（最后一个悬而未决的问题）
用户多次反馈历史记录卡片显示"细长"，团队名称/比分不显示。

**当前方案（1.2.1）**：
```css
.h-swipe-item { position:relative; overflow:hidden; border-radius:14px; margin-bottom:8px; }
.h-delete-reveal { position:absolute; left:100%; top:0; bottom:0; width:76px; ... }
.h-swipe-item .h-card { margin-bottom:0 !important; border-radius:14px !important; }
```
```javascript
// 卡片和删除键使用相同 translateX
item.querySelectorAll('.h-card,.h-delete-reveal').forEach(el => {
  el.style.transform = `translateX(${x}px)`;
});
```

**理论上应当正确**：卡片是普通块级元素，宽度天然等于父容器，不涉及 flex 百分比。但用户还未测试 1.2.1，如果仍有问题，可以排查：
1. 是否有其他 CSS 规则（Android media query 内）覆盖了 `.h-card` 的 `width` 或 `display`
2. 在 Android WebView DevTools 中检查 `.h-swipe-item .h-card` 的 computed width

### ⚠️ 导出文件在真机上未验证
1.2.0 APK 因 JS 语法错误（整个脚本崩溃）无法测试任何功能，1.2.1 才修复。`ScoreboardBridge.saveToDownloads` 的逻辑在代码层面正确，但真机行为未经用户确认。

### 💡 可以继续做的功能（用户提到过但未实现）
- 更多主题颜色
- 比赛内截图分享
- 多语言支持

---

## 五、index.html 关键位置索引

| 内容 | 大约行号 |
|------|---------|
| CSS 变量 / 主题 | 1–80 |
| `.screen` 通用样式 | 268–278 |
| 首页 CSS | 283–320 |
| 设置页 CSS | 323–430 |
| 比赛页 CSS | 430–500 |
| 菜单 / 胜利遮罩 CSS | 497–570 |
| 历史记录 CSS | 550–910 |
| Android 平台特化 CSS（media query 内）| 726–810 |
| 滑动删除 CSS | 855–878 |
| HTML 结构开始 | 964 |
| 首页 HTML | 964–974 |
| 设置页 HTML | 975–1023 |
| 比赛页 HTML | 1028–1065 |
| 历史页 HTML | 1067–1077 |
| 平台检测 / APP_PLATFORM | 1186 |
| `navTo()` | 1223 |
| `setSport()` | 1288 |
| `startGame()` | 1506 |
| `mkState()` / `addPt()` / `addBB()` | 1521–1637 |
| `render()` | 1638 |
| `renderHistoryList()` | 1865 |
| `buildMatchupView()` | 1912 |
| `openDetail()` / 详情页渲染 | 1981 |
| `buildHistorySummary()` | 2261 |
| Analytics（走势图/分段/关键球/节奏）| 2100–2520 |
| `initSwipeDelete()` | 2525 |
| `exportHistory()` | 2588 |
| `importHistory()` | 2745 |
| Demo 数据生成（`genMatch` 等）| 2814–2933 |

---

## 六、MainActivity.java 结构

```java
public class MainActivity extends BridgeActivity {
    // 内部类：原生文件保存桥
    public class ScoreboardBridge {
        @JavascriptInterface
        public String saveToDownloads(String filename, String content) { ... }
    }

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // 1. 注册 JS 桥（必须在页面加载前）
        bridge.getWebView().addJavascriptInterface(new ScoreboardBridge(), "ScoreboardBridge");
        // 2. Edge-to-edge 设置
        // 3. 刘海屏适配
        // 4. 状态栏图标颜色
        // 5. Android 返回键拦截
        // 6. Safe area insets → CSS 变量注入
    }
}
```
