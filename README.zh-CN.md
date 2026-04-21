# Clawd on Mac

<p align="center">
  <a href="README.md">English</a>
</p>

一个 macOS 原生桌面宠物 + AI Skills 管理应用, 使用 Swift 开发. 实时响应 AI 编码 Agent 的工作状态, 并提供统一的 Skills 管理界面.

> 本项目基于以下两个开源项目的设计理念与功能参考开发而来:
>
> - [**Clawd on Desk**](https://github.com/rullerzhou-afk/clawd-on-desk) — Electron 实现的跨平台桌面宠物, 提供了动画状态机, 多 Agent 支持, 权限审批气泡等核心玩法.
> - [**Skills Manager**](https://github.com/xingkongliang/skills-manager) — Tauri + React 实现的 AI Agent Skills 管理工具, 提供了 Marketplace, 多工具同步, Scenarios 等 Skills 管理能力.
>
> Clawd on Mac 将两者的能力整合到一个 macOS 原生应用中, 以 Swift + AppKit 重写, 追求更低的资源占用和更好的系统集成体验.

## 功能特性

### 桌面宠物

- **Multi-Agent 支持** — Claude Code, Codex CLI, Copilot CLI, Gemini CLI, Cursor Agent, CodeBuddy, Kiro CLI, OpenCode, Pi
- **实时状态感知** — 通过 command hooks, log polling, plugin events 驱动动画状态切换
- **12+ 动画状态** — idle, thinking, working, juggling, error, attention, notification, carrying, sleeping, sweeping 等
- **眼球追踪** — 宠物跟随鼠标, 带有身体倾斜和阴影拉伸效果
- **睡眠序列** — 闲置后自动进入打哈欠, 打盹, 睡眠的完整动画序列; 鼠标移动触发惊醒动画
- **迷你模式** — 拖到屏幕边缘进入迷你模式, 支持 peek-on-hover, crabwalk, parabolic jump 等过渡动画
- **权限审批气泡** — Claude Code / CodeBuddy / OpenCode 权限请求以气泡卡片形式弹出, 支持 Allow / Deny / Suggestions
- **主题系统** — 完整的主题加载系统, 支持自定义主题文件监听与热加载
- **音效提示** — 任务完成和权限请求时播放音效

### Skills 管理 (Dashboard)

- **Skills 扫描与导入** — 扫描本地 skills 目录, 导入并管理 AI Agent Skills
- **Marketplace 集成** — 集成 [skills.sh](https://skills.sh) Marketplace, 支持 alltime / trending / hot 排行榜
- **Git 仓库源** — 支持从 Git 仓库安装和更新 Skills
- **多工具同步** — 将 skills 同步到不同的 AI Agent 工具
- **项目管理** — 管理项目级的 skill 配置
- **Scenarios** — 技能分组方案, 快速切换不同配置集
- **Git 备份** — 使用 Git 版本控制备份 skill 库

### 系统功能

- **点击穿透** — 透明区域穿透点击, 仅宠物本体可交互
- **位置记忆** — 跨重启记忆宠物位置 (包括 mini mode 状态)
- **单实例锁** — 文件锁确保单实例运行
- **免打扰模式** — 暂停所有 hook 事件与权限气泡
- **系统状态栏** — 含尺寸切换, DND, 语言切换, Dashboard 入口等
- **多语言** — English, 中文, 韩语
- **自动更新** — 自动检查新版本

## 技术栈

| 层级 | 技术 |
|---|---|
| 语言 | Swift 5.9 |
| UI 框架 | AppKit + WKWebView (Dashboard) |
| 构建系统 | XcodeGen (`project.yml`) |
| 存储 | SQLite (`libsqlite3`) |
| 网络 | Network.framework (HTTP server) |
| 最低版本 | macOS 13.0 |

## 项目结构

```
Sources/
  App/            — 应用入口与 AppDelegate
  Agents/         — Agent 注册表, Codex/Gemini 日志监控
  Animation/      — 迷你模式控制器
  Audio/          — 音效管理
  Bubble/         — 权限审批气泡窗口
  Dashboard/      — Skills 管理 UI (HTML/CSS/JS in WKWebView)
  EyeTracking/    — 鼠标追踪 (眼球跟随)
  Hooks/          — Agent 集成 Hook 注册
  i18n/           — 国际化
  Menu/           — 右键菜单与状态栏菜单
  Reactions/      — 点击反应处理
  Rendering/      — 基于 WebView 的宠物渲染
  Server/         — 内置 HTTP 服务器 (Hook 端点)
  Settings/       — 用户偏好与设置 UI
  Skills/         — Skill 扫描, 导入, 同步, Marketplace
  State/          — 宠物状态机 (PetStateActor)
  Theme/          — 主题加载与文件监听
  Update/         — 自动更新检查
  Windows/        — 渲染窗口与输入窗口控制器
Resources/
  themes/         — 内置主题
  sounds/         — 音频资源
  hooks/          — Hook 脚本模板
  dashboard/      — Dashboard Web 资源
  icons/          — 应用图标
  en.lproj/       — 英语本地化
  zh.lproj/       — 中文本地化
  ko.lproj/       — 韩语本地化
```

## 安装

从 [Releases](../../releases) 页面下载 `ClawdOnMac.zip`, 解压后将 `ClawdOnMac.app` 拖入 `/Applications`.

> **注意:** 本应用未使用 Apple Developer 证书签名, macOS Gatekeeper 会在首次启动时拦截. 请执行以下命令解除限制:
>
> ```bash
> xattr -cr /Applications/ClawdOnMac.app
> ```
>
> 或者: 右键点击应用 -> 打开 -> 在弹出的对话框中确认.

## 快速开始

### 前置条件

- macOS 13.0+
- Xcode 15.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### 构建

```bash
# 从 project.yml 生成 Xcode 项目
xcodegen generate

# 在 Xcode 中打开并构建
open ClawdOnMac.xcodeproj
```

或通过命令行构建:

```bash
xcodebuild -project ClawdOnMac.xcodeproj -scheme ClawdOnMac -configuration Release build
```

## 致谢

- [Clawd on Desk](https://github.com/rullerzhou-afk/clawd-on-desk) by [@rullerzhou-afk](https://github.com/rullerzhou-afk) — 桌面宠物的功能设计参考与动画资产来源
- [Skills Manager](https://github.com/xingkongliang/skills-manager) by [@xingkongliang](https://github.com/xingkongliang) — Skills 管理能力的功能设计参考

## 许可证

MIT
