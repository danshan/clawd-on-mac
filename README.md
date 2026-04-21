# Clawd on Mac

<p align="center">
  <a href="README.zh-CN.md">中文版</a>
</p>

A native macOS desktop pet + AI Skills management app, built with Swift. Reacts to your AI coding agent sessions in real-time and provides a unified skills management dashboard.

> This project is developed based on two open-source projects:
>
> - [**Clawd on Desk**](https://github.com/rullerzhou-afk/clawd-on-desk) — An Electron-based cross-platform desktop pet with animated state machine, multi-agent support, permission approval bubbles, and more.
> - [**Skills Manager**](https://github.com/xingkongliang/skills-manager) — A Tauri + React AI agent skills management tool with marketplace integration, multi-tool sync, scenarios, and more.
>
> Clawd on Mac combines the capabilities of both into a single native macOS application, rewritten in Swift + AppKit for lower resource usage and tighter system integration.

## Features

### Desktop Pet

- **Multi-Agent support** — Claude Code, Codex CLI, Copilot CLI, Gemini CLI, Cursor Agent, CodeBuddy, Kiro CLI, OpenCode, Pi
- **Real-time state awareness** — driven by command hooks, log polling, and plugin events
- **12+ animated states** — idle, thinking, working, juggling, error, attention, notification, carrying, sleeping, sweeping, etc.
- **Eye tracking** — follows your cursor with body lean and shadow stretch
- **Sleep sequence** — yawning, dozing, collapsing, sleeping after idle timeout; mouse movement triggers wake-up
- **Mini mode** — drag to screen edge for mini mode with peek-on-hover, crabwalk, and parabolic jump transitions
- **Permission bubble** — Claude Code / CodeBuddy / OpenCode permission requests pop up as floating bubble cards with Allow / Deny / Suggestions
- **Theme system** — full theme loading with file monitoring and hot reload
- **Sound effects** — audio cues on task completion and permission requests

### Skills Management (Dashboard)

- **Skills scanning & import** — scan local skills directories, import and manage AI agent skills
- **Marketplace integration** — browse [skills.sh](https://skills.sh) marketplace with alltime / trending / hot leaderboards
- **Git repo as source** — install and update skills from Git repositories
- **Multi-tool sync** — sync skills to different AI agent tools
- **Project management** — manage project-level skill configurations
- **Scenarios** — group skills into switchable configuration sets
- **Git backup** — version-control your skill library with Git

### System

- **Click-through** — transparent areas pass clicks to windows below; only the pet body is interactive
- **Position memory** — remembers position across restarts (including mini mode state)
- **Single instance lock** — file lock ensures only one instance runs
- **Do Not Disturb** — silences all hook events and permission bubbles
- **System tray** — status bar menu with size toggle, DND, language switch, dashboard access, etc.
- **i18n** — English, Chinese, Korean
- **Auto-update** — checks for new releases automatically

## Tech Stack

| Layer | Tech |
|---|---|
| Language | Swift 5.9 |
| UI Framework | AppKit + WKWebView (Dashboard) |
| Build System | XcodeGen (`project.yml`) |
| Storage | SQLite (`libsqlite3`) |
| Networking | Network.framework (HTTP server) |
| Min Deployment | macOS 13.0 |

## Project Structure

```
Sources/
  App/            — Application entry point and AppDelegate
  Agents/         — Agent registry, Codex/Gemini log monitors
  Animation/      — Mini mode controller
  Audio/          — Sound effect management
  Bubble/         — Permission approval bubble windows
  Dashboard/      — Skills management UI (HTML/CSS/JS in WKWebView)
  EyeTracking/    — Mouse tracking for eye follow
  Hooks/          — Hook registration for agent integrations
  i18n/           — Localization
  Menu/           — Context menu and tray menu
  Reactions/      — Click reaction handlers
  Rendering/      — WebView-based pet rendering
  Server/         — Built-in HTTP server for hook endpoints
  Settings/       — User preferences and settings UI
  Skills/         — Skill scanning, importing, syncing, marketplace
  State/          — Pet state machine (PetStateActor)
  Theme/          — Theme loading and file monitoring
  Update/         — Auto-update checker
  Windows/        — Render window and input window controllers
Resources/
  themes/         — Built-in themes
  sounds/         — Audio assets
  hooks/          — Hook script templates
  dashboard/      — Dashboard web assets
  icons/          — App icons
  en.lproj/       — English localization
  zh.lproj/       — Chinese localization
  ko.lproj/       — Korean localization
```

## Install

Download `ClawdOnMac.zip` from the [Releases](../../releases) page, unzip, and drag `ClawdOnMac.app` to `/Applications`.

> **Note:** This app is not signed with an Apple Developer certificate. macOS Gatekeeper will block it on first launch. To allow it, run:
>
> ```bash
> xattr -cr /Applications/ClawdOnMac.app
> ```
>
> Or: right-click the app → Open → confirm in the dialog.

## Getting Started

### Prerequisites

- macOS 13.0+
- Xcode 15.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### Build

```bash
# Generate Xcode project from project.yml
xcodegen generate

# Open in Xcode and build
open ClawdOnMac.xcodeproj
```

Or build from command line:

```bash
xcodebuild -project ClawdOnMac.xcodeproj -scheme ClawdOnMac -configuration Release build
```

## Acknowledgments

- [Clawd on Desk](https://github.com/rullerzhou-afk/clawd-on-desk) by [@rullerzhou-afk](https://github.com/rullerzhou-afk) — design reference and animation assets for the desktop pet
- [Skills Manager](https://github.com/xingkongliang/skills-manager) by [@xingkongliang](https://github.com/xingkongliang) — design reference for skills management capabilities

## License

MIT
