import AppKit
import os
import ServiceManagement

private let logger = Logger(subsystem: "com.clawd.ClawdOnMac", category: "App")

class AppDelegate: NSObject, NSApplicationDelegate {

    private var trayItem: NSStatusItem?
    private var renderWindowController: RenderWindowController?
    private var inputWindowController: InputWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var miniModeController: MiniModeController?
    private var cachedDND: Bool = false
    private var cachedSessions: [SessionState] = []
    private var cachedDisplayState: String = "idle"

    private(set) lazy var settings = SettingsController()
    private let stateActor = PetStateActor()
    private let themeLoader = ThemeLoader()
    private lazy var httpServer = HTTPServer(stateActor: stateActor, themeLoader: themeLoader)
    private lazy var audioManager = AudioManager()
    private lazy var mouseTracker = MouseTracker()
    private lazy var displayObserver = DisplayChangeObserver()
    private lazy var hookRegistrar = HookRegistrar()
    private lazy var bubbleManager = BubbleManager()
    private lazy var themeMonitor = ThemeFileMonitor()
    private lazy var codexMonitor = CodexLogMonitor()
    private lazy var geminiMonitor = GeminiLogMonitor()

    private var lockFileDescriptor: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance guard using file lock
        if !acquireInstanceLock() {
            logger.warning("Another instance already running, terminating self")
            // Brief delay to ensure log is flushed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.terminate(nil)
            }
            return
        }

        logger.info("applicationDidFinishLaunching started")
        NSApp.setActivationPolicy(settings.get(\.showDock) ? .regular : .accessory)

        NotificationCenter.default.addObserver(
            self, selector: #selector(openPreferences),
            name: .init("openPreferences"), object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePetStateChanged),
            name: .init("petStateChanged"), object: nil
        )

        setupSettingsSubscribers()
        if settings.get(\.showTray) {
            setupTray()
        }
        setupWindows()
        setupMouseTracking()
        setupDisplayObserver()
        setupThemeMonitor()
        startHTTPServer()
        registerHooks()
        setupLogMonitors()

        // Hydrate soundMuted from prefs into audio manager
        audioManager.isMuted = settings.get(\.soundMuted)

        // Hydrate login item state from system
        hydrateLoginItemState()

        // Register global hotkey (Cmd+Shift+Option+C)
        setupGlobalHotkey()

        // Silent update check on startup
        UpdateChecker.shared.checkForUpdates()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Save window position, mini mode state, and display state before quit
        if let frame = renderWindowController?.window?.frame {
            let isMini = miniModeController?.miniMode ?? false
            var bulk: [(key: String, value: Any)] = [
                (key: "x", value: frame.origin.x),
                (key: "y", value: frame.origin.y),
                (key: "positionSaved", value: true),
                (key: "miniMode", value: isMini),
                (key: "lastDisplayState", value: cachedDisplayState),
            ]
            if let edge = miniModeController?.miniEdge {
                bulk.append((key: "miniEdge", value: edge == .left ? "left" : "right"))
            }
            _ = settings.applyBulk(bulk)
        }
        NotificationCenter.default.removeObserver(self)
        renderWindowController?.cleanupTempFiles()
        teardownGlobalHotkey()
        mouseTracker.stop()
        codexMonitor.stop()
        geminiMonitor.stop()
        themeMonitor.stop()
        displayObserver.stop()
        httpServer.shutdown()
        RuntimeConfig.cleanup()
        settings.store.dispose()
        releaseInstanceLock()
    }

    // MARK: - Settings subscribers

    private func setupSettingsSubscribers() {
        settings.subscribeKey(\.lang) { [weak self] lang, _ in
            I18n.shared.setLanguage(lang)
            self?.rebuildMenu()
        }

        settings.subscribeKey(\.soundMuted) { [weak self] muted, _ in
            self?.audioManager.isMuted = muted
            self?.rebuildMenu()
        }

        settings.subscribeKey(\.theme) { [weak self] themeName, _ in
            guard let self = self else { return }
            if let theme = self.themeLoader.loadTheme(named: themeName) {
                self.renderWindowController?.reloadTheme(theme, loader: self.themeLoader)
                // Update input window height ratio for new theme
                let vhr = CGFloat(theme.layout?.visibleHeightRatio ?? 0.6)
                let bbr = CGFloat(theme.layout?.baselineBottomRatio ?? 0.05)
                WindowSizeManager.computeHitRatios(from: theme)
                // Re-apply size to resize input window
                let currentSize = self.settings.get(\.size)
                WindowSizeManager.applySize(
                    currentSize.isEmpty ? "P:10" : currentSize,
                    renderWindow: self.renderWindowController?.window,
                    inputWindow: self.inputWindowController?.window
                )
                Task {
                    await self.stateActor.setDisplayHintMap(theme.displayHintMap ?? [:])
                    await self.stateActor.setHitboxConfig(
                        hitBoxes: theme.hitBoxes ?? [:],
                        wideSVGs: theme.wideHitboxFiles ?? [],
                        sleepingSVGs: theme.sleepingHitboxFiles ?? []
                    )
                }
            }
            self.rebuildMenu()
        }

        settings.subscribeKey(\.size) { [weak self] sizeStr, _ in
            guard let self = self else { return }
            WindowSizeManager.applySize(
                sizeStr,
                renderWindow: self.renderWindowController?.window,
                inputWindow: self.inputWindowController?.window
            )
            self.rebuildMenu()
        }

        settings.subscribeKey(\.sleepMode) { [weak self] mode, _ in
            guard let self = self else { return }
            Task {
                await self.stateActor.setSleepMode(mode == "direct" ? .direct : .full)
            }
        }

        settings.subscribeKey(\.showDock) { [weak self] show, _ in
            NSApp.setActivationPolicy(show ? .regular : .accessory)
            self?.rebuildMenu()
        }
        settings.subscribeKey(\.showTray) { [weak self] show, _ in
            if show {
                self?.setupTray()
            } else {
                if let item = self?.trayItem {
                    NSStatusBar.system.removeStatusItem(item)
                    self?.trayItem = nil
                }
            }
            self?.rebuildMenu()
        }

        // When an agent is toggled off externally, dismiss its pending bubbles
        settings.subscribeKey(\.agents) { [weak self] agents, _ in
            guard let self = self else { return }
            for agent in AgentRegistry.shared.agents {
                let enabled = agents[agent.id]?.enabled ?? false
                if !enabled {
                    self.bubbleManager.dismissBubbles(forAgent: agent.id)
                }
            }
            self.rebuildMenu()
        }
    }

    private func setupTray() {
        logger.info("Setting up tray...")
        trayItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = trayItem?.button {
            if let iconURL = Bundle.main.url(forResource: "tray-iconTemplate@2x", withExtension: "png", subdirectory: "icons"),
               let image = NSImage(contentsOf: iconURL) {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                button.image = image
            }
        }
        trayItem?.menu = buildMenu()
        logger.info("Tray setup complete")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let i18n = I18n.shared

        // DND / Mini mode
        let dndItem = NSMenuItem(
            title: isDND() ? i18n.t("wake") : i18n.t("sleep"),
            action: #selector(toggleDND),
            keyEquivalent: ""
        )
        dndItem.target = self
        menu.addItem(dndItem)

        let miniItem = NSMenuItem(
            title: miniModeController?.miniMode == true ? i18n.t("exitMiniMode") : i18n.t("miniMode"),
            action: #selector(toggleMiniMode),
            keyEquivalent: "m"
        )
        miniItem.target = self
        menu.addItem(miniItem)

        menu.addItem(NSMenuItem.separator())

        // Bubble / Sound toggles
        let bubbleFollowItem = NSMenuItem(title: i18n.t("bubbleFollow"), action: #selector(toggleBubbleFollow(_:)), keyEquivalent: "")
        bubbleFollowItem.target = self
        bubbleFollowItem.state = settings.get(\.bubbleFollowPet) ? .on : .off
        menu.addItem(bubbleFollowItem)

        let hideBubblesItem = NSMenuItem(title: i18n.t("hideBubbles"), action: #selector(toggleHideBubbles(_:)), keyEquivalent: "")
        hideBubblesItem.target = self
        hideBubblesItem.state = settings.get(\.hideBubbles) ? .on : .off
        menu.addItem(hideBubblesItem)

        let soundItem = NSMenuItem(title: i18n.t("soundEffects"), action: #selector(toggleSound(_:)), keyEquivalent: "")
        soundItem.target = self
        soundItem.state = settings.get(\.soundMuted) ? .off : .on
        menu.addItem(soundItem)

        let dockItem = NSMenuItem(title: i18n.t("showInDock"), action: #selector(toggleDockIcon(_:)), keyEquivalent: "")
        dockItem.target = self
        dockItem.state = settings.get(\.showDock) ? .on : .off
        dockItem.isEnabled = settings.get(\.showDock) ? settings.get(\.showTray) : true
        menu.addItem(dockItem)

        let trayItem = NSMenuItem(title: i18n.t("showInMenuBar"), action: #selector(toggleTrayIcon(_:)), keyEquivalent: "")
        trayItem.target = self
        trayItem.state = settings.get(\.showTray) ? .on : .off
        trayItem.isEnabled = settings.get(\.showTray) ? settings.get(\.showDock) : true
        menu.addItem(trayItem)

        let sessionIdItem = NSMenuItem(title: i18n.t("showSessionId"), action: #selector(toggleShowSessionId(_:)), keyEquivalent: "")
        sessionIdItem.target = self
        sessionIdItem.state = settings.get(\.showSessionId) ? .on : .off
        menu.addItem(sessionIdItem)

        menu.addItem(NSMenuItem.separator())

        // Startup toggles
        let loginItem = NSMenuItem(title: i18n.t("startOnLogin"), action: #selector(toggleStartOnLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = settings.get(\.openAtLogin) ? .on : .off
        menu.addItem(loginItem)

        let claudeItem = NSMenuItem(title: i18n.t("startWithClaude"), action: #selector(toggleStartWithClaude(_:)), keyEquivalent: "")
        claudeItem.target = self
        claudeItem.state = settings.get(\.autoStartWithClaude) ? .on : .off
        menu.addItem(claudeItem)

        menu.addItem(NSMenuItem.separator())

        // Theme submenu
        let themeMenu = NSMenu()
        for name in ["clawd", "calico"] {
            let item = NSMenuItem(title: name.capitalized, action: #selector(switchTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = settings.get(\.theme) == name ? .on : .off
            themeMenu.addItem(item)
        }
        themeMenu.addItem(NSMenuItem.separator())
        let openThemeDirItem = NSMenuItem(title: i18n.t("openThemeDir"), action: #selector(openThemeDirectory), keyEquivalent: "")
        openThemeDirItem.target = self
        themeMenu.addItem(openThemeDirItem)
        let themeItem = NSMenuItem(title: i18n.t("theme"), action: nil, keyEquivalent: "")
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        // Size submenu
        let sizeMenu = NSMenu()
        let currentSize = settings.get(\.size)
        for (label, ratio) in WindowSizeManager.presets {
            let item = NSMenuItem(title: i18n.t("proportionalPct", ["n": "\(Int(ratio))"]), action: #selector(changeSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = label
            item.state = currentSize == label ? .on : .off
            sizeMenu.addItem(item)
        }
        let sizeItem = NSMenuItem(title: i18n.t("size"), action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        // Display submenu (multi-monitor)
        let displays = WindowSizeManager.availableDisplays()
        if displays.count > 1 {
            let displayMenu = NSMenu()
            for (i, display) in displays.enumerated() {
                let item = NSMenuItem(title: display.name, action: #selector(sendToDisplay(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                displayMenu.addItem(item)
            }
            let displayItem = NSMenuItem(title: i18n.t("sendToDisplay"), action: nil, keyEquivalent: "")
            displayItem.submenu = displayMenu
            menu.addItem(displayItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Agents submenu
        let agentMenu = NSMenu()
        let agentConfigs = settings.get(\.agents)
        for agent in AgentRegistry.shared.agents {
            let hookInstalled = hookRegistrar.isHookInstalled(agentId: agent.id)
            let enabled = agentConfigs[agent.id]?.enabled ?? hookInstalled
            let item = NSMenuItem(title: agent.name, action: #selector(toggleAgent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = agent.id
            item.state = enabled ? .on : .off
            agentMenu.addItem(item)
        }
        let agentItem = NSMenuItem(title: i18n.t("agents"), action: nil, keyEquivalent: "")
        agentItem.submenu = agentMenu
        menu.addItem(agentItem)

        menu.addItem(NSMenuItem.separator())

        // Sessions
        let sessionCount = cachedSessions.count
        let sessionMenu = NSMenu()
        if cachedSessions.isEmpty {
            let noSession = NSMenuItem(title: i18n.t("noSessions"), action: nil, keyEquivalent: "")
            noSession.isEnabled = false
            sessionMenu.addItem(noSession)
        } else {
            for session in cachedSessions {
                let badge = session.state.rawValue
                let agentId = session.agentId ?? "unknown"
                let agentDef = AgentRegistry.shared.getAgent(agentId)
                let agentName = agentDef?.name ?? agentId
                let title = "\(agentName) — \(badge)"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                if let symbol = agentDef?.systemSymbol,
                   let img = NSImage(systemSymbolName: symbol, accessibilityDescription: agentName) {
                    item.image = img
                }
                item.isEnabled = false
                sessionMenu.addItem(item)
            }
        }
        let sessionItem = NSMenuItem(
            title: "\(i18n.t("sessions")) (\(sessionCount))",
            action: nil, keyEquivalent: ""
        )
        sessionItem.submenu = sessionMenu
        menu.addItem(sessionItem)

        menu.addItem(NSMenuItem.separator())

        // Settings
        let settingsItem = NSMenuItem(title: i18n.t("settings"), action: #selector(openPreferences), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Dashboard
        let dashboardItem = NSMenuItem(title: "Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        dashboardItem.target = self
        menu.addItem(dashboardItem)

        menu.addItem(NSMenuItem.separator())

        // Language submenu
        let langMenu = NSMenu()
        let currentLang = settings.get(\.lang)
        for (label, code) in [("English", "en"), ("中文", "zh"), ("한국어", "ko")] {
            let item = NSMenuItem(title: label, action: #selector(switchLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = currentLang == code ? .on : .off
            langMenu.addItem(item)
        }
        let langItem = NSMenuItem(title: i18n.t("language"), action: nil, keyEquivalent: "")
        langItem.submenu = langMenu
        menu.addItem(langItem)

        menu.addItem(NSMenuItem.separator())

        // Show/Hide pet
        let petVisible = renderWindowController?.window?.isVisible ?? true
        let togglePetItem = NSMenuItem(
            title: petVisible ? i18n.t("hidePet") : i18n.t("showPet"),
            action: #selector(togglePetVisibility),
            keyEquivalent: ""
        )
        togglePetItem.target = self
        menu.addItem(togglePetItem)

        menu.addItem(NSMenuItem.separator())

        // Version + Update
        let versionTitle = "v\(UpdateChecker.shared.currentVersion)"
        let versionItem = NSMenuItem(title: versionTitle, action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let checkUpdateItem = NSMenuItem(title: i18n.t("checkForUpdates"), action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdateItem.target = self
        menu.addItem(checkUpdateItem)

        menu.addItem(NSMenuItem.separator())

        // Shortcut info
        let shortcutItem = NSMenuItem(
            title: i18n.t("toggleShortcut", ["shortcut": "⌘⇧⌥C"]),
            action: nil, keyEquivalent: ""
        )
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: i18n.t("quit"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func setupWindows() {
        logger.info("Setting up windows...")
        // Load theme from user prefs (fallback to default)
        let preferredTheme = settings.get(\.theme)
        guard let theme = themeLoader.loadTheme(named: preferredTheme) ?? themeLoader.loadDefaultTheme() else {
            logger.error("Failed to load default theme")
            return
        }
        logger.info("Theme loaded: \(theme.name)")

        // Wire theme data into state machine
        Task {
            await stateActor.setDisplayHintMap(theme.displayHintMap ?? [:])
            await stateActor.setHitboxConfig(
                hitBoxes: theme.hitBoxes ?? [:],
                wideSVGs: theme.wideHitboxFiles ?? [],
                sleepingSVGs: theme.sleepingHitboxFiles ?? []
            )
        }

        renderWindowController = RenderWindowController(theme: theme, stateActor: stateActor, themeLoader: themeLoader)
        renderWindowController?.onSVGLoaded = { [weak self] filename in
            guard let self = self else { return }
            Task {
                let hitBox = await self.stateActor.hitboxForSVG(filename)
                await MainActor.run {
                    WindowSizeManager.computeHitRatios(from: theme, hitBox: hitBox)
                    WindowSizeManager.updatePetHitRect(inputWindow: self.inputWindowController?.window)
                }
            }
        }
        renderWindowController?.showWindow(nil)

        // Configure hit rect ratios from theme data (hitBox + layout + viewBox)
        WindowSizeManager.computeHitRatios(from: theme)

        inputWindowController = InputWindowController(stateActor: stateActor)
        inputWindowController?.settings = settings
        inputWindowController?.renderWindowController = renderWindowController
        inputWindowController?.bubbleManager = bubbleManager
        inputWindowController?.showWindow(nil)

        // Wire mini mode controller
        let mini = MiniModeController()
        mini.renderWindow = renderWindowController?.window
        mini.inputWindow = inputWindowController?.window
        mini.stateActor = stateActor
        if let offsetRatio = theme.miniMode?.offsetRatio {
            mini.configure(offsetRatio: offsetRatio)
        }
        mini.onMiniStateChanged = { [weak self] isMini in
            (self?.inputWindowController?.window as? InputPanel)?.isMiniMode = isMini
            self?.renderWindowController?.syncFromStateActor()
        }
        miniModeController = mini
        inputWindowController?.miniModeController = mini

        // Apply initial size from preferences (or default P:10)
        let initialSize = settings.get(\.size)
        WindowSizeManager.applySize(
            initialSize.isEmpty ? "P:10" : initialSize,
            renderWindow: renderWindowController?.window,
            inputWindow: inputWindowController?.window
        )

        // Restore window position from prefs, or default to bottom-right
        if let rw = renderWindowController?.window, let screen = rw.screen ?? NSScreen.main {
            let wa = screen.visibleFrame
            let petSize = rw.frame.size
            let savedX = settings.get(\.x)
            let savedY = settings.get(\.y)
            let hasSaved = settings.get(\.positionSaved)

            let origin: CGPoint
            if hasSaved && wa.contains(CGPoint(x: savedX, y: savedY)) {
                origin = CGPoint(x: savedX, y: savedY)
            } else {
                origin = CGPoint(x: wa.maxX - petSize.width - 20, y: wa.origin.y + 20)
            }
            rw.setFrameOrigin(origin)
            inputWindowController?.window?.setFrameOrigin(origin)
        }

        logger.info("Windows setup complete, frame: \(self.renderWindowController?.window?.frame.debugDescription ?? "nil")")

        // Restore sleep mode preference and last display state
        let sleepModePref = settings.get(\.sleepMode)
        let lastState = settings.get(\.lastDisplayState)
        Task {
            await stateActor.setSleepMode(sleepModePref == "direct" ? .direct : .full)
            if lastState != "idle" {
                await stateActor.restoreDisplayState(lastState)
            }
        }

        // Restore mini mode state from prefs
        if settings.get(\.miniMode) {
            miniModeController?.enterViaMenu()
        }
    }

    private func setupMouseTracking() {
        mouseTracker.onMouseMove = { [weak self] position in
            self?.handleMouseMove(position)
        }
        mouseTracker.start()
    }

    private func handleMouseMove(_ position: CGPoint) {
        Task {
            await stateActor.updateMousePosition(position)
        }
        renderWindowController?.updateEyeTracking(position: position)
    }

    private func setupDisplayObserver() {
        displayObserver.onDisplayChanged = { [weak self] in
            guard let self = self else { return }
            // Re-apply proportional sizing on display change
            let sizeStr = self.settings.get(\.size)
            WindowSizeManager.applySize(
                sizeStr,
                renderWindow: self.renderWindowController?.window,
                inputWindow: self.inputWindowController?.window
            )
            // Reposition mini mode if active
            self.miniModeController?.handleDisplayChange()
        }
        displayObserver.start()
    }

    private func setupThemeMonitor() {
        let themesDir = themeLoader.themesDirectory
        guard !themesDir.isEmpty else { return }
        themeMonitor.onChange = { [weak self] in
            guard let self else { return }
            let themeName = self.settings.get(\.theme)
            self.themeLoader.clearCache(for: themeName)
            if let theme = self.themeLoader.loadTheme(named: themeName) {
                self.renderWindowController?.reloadTheme(theme, loader: self.themeLoader)
                logger.info("Theme hot-reloaded: \(themeName)")
            }
        }
        themeMonitor.start(directory: themesDir)
    }

    private func startHTTPServer() {
        logger.info("Starting HTTP server on port 23333-23337...")
        httpServer.bubbleManager = bubbleManager
        httpServer.getPetFrame = { [weak self] in
            self?.renderWindowController?.window?.frame ?? NSRect(x: 100, y: 100, width: 150, height: 100)
        }
        httpServer.isAgentEnabled = { [weak self] agentId in
            guard let self = self else { return false }
            let hookInstalled = self.hookRegistrar.isHookInstalled(agentId: agentId)
            guard hookInstalled else { return false }
            let agents = self.settings.get(\.agents)
            return agents[agentId]?.enabled ?? true
        }
        httpServer.isAgentPermissionsEnabled = { [weak self] agentId in
            let agents = self?.settings.get(\.agents) ?? [:]
            return agents[agentId]?.permissionsEnabled ?? true
        }
        httpServer.isDND = { [weak self] in
            self?.cachedDND ?? false
        }
        httpServer.isHideBubbles = { [weak self] in
            self?.settings.get(\.hideBubbles) ?? false
        }
        httpServer.getSettings = { [weak self] in
            guard let self = self else { return [:] }
            let snapshot = self.settings.getSnapshot()
            guard let data = try? JSONEncoder().encode(snapshot),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [:]
            }
            return dict
        }
        httpServer.updateSetting = { [weak self] key, value in
            guard let self = self else { return "error" }
            let result = self.settings.applyUpdate(key, value: value)
            switch result.status {
            case .ok: return "ok"
            case .noop: return "noop"
            case .error: return "error: \(result.message ?? "unknown")"
            }
        }
        httpServer.skillsManager = {
            do {
                let sm = try SkillsManager()
                // Re-parse SKILL.md to update stale descriptions in DB
                DispatchQueue.global(qos: .utility).async { sm.rescanDescriptions() }
                return sm
            } catch {
                logger.error("Failed to init SkillsManager: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }()
        httpServer.start()
        logger.info("HTTP server start() returned")
    }

    private func registerHooks() {
        guard settings.get(\.manageClaudeHooksAutomatically) else { return }
        let port = httpServer.activePort ?? 23333

        // Check for wipe before registering (e.g. Claude Code reset settings.json)
        if !hookRegistrar.areClaudeHooksRegistered() {
            logger.info("Claude hooks not found (first run or wipe detected), registering")
        }

        let result = hookRegistrar.registerAllHooks(port: port)
        logger.info("Registered \(result.total) hooks (skipped \(result.skipped))")
    }

    private func setupLogMonitors() {
        let agentConfigs = settings.get(\.agents)

        // Codex log monitor
        if AgentRegistry.shared.isAgentEnabled("codex", agents: agentConfigs) {
            codexMonitor.onStateChange = { [weak self] sessionId, state, event, extra in
                guard let self = self else { return }
                if state == "codex-permission" {
                    // Show notification bubble with command info
                    Task { @MainActor in
                        await self.stateActor.updateSession(
                            sessionId, state: "notification", event: "PermissionRequest",
                            sourcePid: nil, cwd: nil,
                            agentId: "codex", displayHint: nil
                        )
                        let command = extra["command"] ?? ""
                        let text = command.isEmpty ? "Codex waiting for approval" : "Codex: \(command)"
                        let petFrame = self.renderWindowController?.window?.frame ?? .zero
                        self.bubbleManager.showNotification(text, sessionId: sessionId, petFrame: petFrame, duration: 15)
                    }
                    return
                }
                Task {
                    await self.stateActor.updateSession(
                        sessionId, state: state, event: event,
                        sourcePid: nil, cwd: nil,
                        agentId: "codex", displayHint: nil
                    )
                }
            }
            codexMonitor.start()
        }

        // Gemini log monitor
        if AgentRegistry.shared.isAgentEnabled("gemini-cli", agents: agentConfigs) {
            geminiMonitor.onStateChange = { [weak self] sessionId, state, event in
                guard let self = self else { return }
                Task {
                    await self.stateActor.updateSession(
                        sessionId, state: state, event: event,
                        sourcePid: nil, cwd: nil,
                        agentId: "gemini-cli", displayHint: nil
                    )
                }
            }
            geminiMonitor.start()
        }
    }

    @objc private func openPreferences() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                settings: settings,
                stateActor: stateActor,
                themeLoader: themeLoader
            )
        }
        settingsWindowController?.showWindow(nil)
    }

    @objc private func openDashboard() {
        let port = httpServer.activePort ?? 23333
        let url = URL(string: "http://localhost:\(port)/dashboard")!
        NSWorkspace.shared.open(url)
    }

    @objc private func handlePetStateChanged() {
        Task {
            let sessions = await stateActor.getActiveSessions()
            let displayState = await stateActor.getCurrentDisplayState()
            await MainActor.run {
                self.cachedSessions = sessions
                self.cachedDisplayState = displayState.rawValue
            }
        }
    }

    @objc private func toggleAgent(_ sender: NSMenuItem) {
        guard let agentId = sender.representedObject as? String else { return }
        let wasEnabled = hookRegistrar.isHookInstalled(agentId: agentId)
        let port = httpServer.activePort ?? 23333

        if wasEnabled {
            hookRegistrar.unregisterHooks(agentId: agentId, port: port)
        } else {
            hookRegistrar.registerHooks(agentId: agentId, port: port)
        }

        var agents = settings.get(\.agents)
        var config = agents[agentId] ?? AgentConfig()
        config.enabled = !wasEnabled
        agents[agentId] = config
        _ = settings.applyUpdate("agents", value: agents)
        rebuildMenu()
    }

    @objc private func toggleMiniMode() {
        guard let mini = miniModeController else { return }
        if mini.miniMode {
            mini.exitMiniMode()
        } else {
            mini.enterViaMenu()
        }
    }

    @objc private func toggleDND() {
        Task {
            await stateActor.toggleDoNotDisturb()
            let newDND = await stateActor.isDoNotDisturb()
            await MainActor.run {
                self.cachedDND = newDND
                self.rebuildMenu()
            }
        }
    }

    @objc private func switchLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        _ = settings.applyUpdate("lang", value: code)
    }

    @objc private func switchTheme(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        _ = settings.applyUpdate("theme", value: name)
    }

    @objc private func changeSize(_ sender: NSMenuItem) {
        guard let sizeStr = sender.representedObject as? String else { return }
        _ = settings.applyUpdate("size", value: sizeStr)
    }

    @objc private func sendToDisplay(_ sender: NSMenuItem) {
        let displays = WindowSizeManager.availableDisplays()
        guard sender.tag < displays.count else { return }
        WindowSizeManager.sendToDisplay(
            displays[sender.tag].screen,
            renderWindow: renderWindowController?.window,
            inputWindow: inputWindowController?.window
        )
    }

    @objc private func toggleBubbleFollow(_ sender: NSMenuItem) {
        let current = settings.get(\.bubbleFollowPet)
        _ = settings.applyUpdate("bubbleFollowPet", value: !current)
        bubbleManager.followPet = !current
        rebuildMenu()
    }

    @objc private func toggleHideBubbles(_ sender: NSMenuItem) {
        let current = settings.get(\.hideBubbles)
        _ = settings.applyUpdate("hideBubbles", value: !current)
        if !current { bubbleManager.dismissAll() }
        rebuildMenu()
    }

    @objc private func toggleSound(_ sender: NSMenuItem) {
        let current = settings.get(\.soundMuted)
        _ = settings.applyUpdate("soundMuted", value: !current)
        rebuildMenu()
    }

    @objc private func toggleDockIcon(_ sender: NSMenuItem) {
        let current = settings.get(\.showDock)
        _ = settings.applyUpdate("showDock", value: !current)
        rebuildMenu()
    }

    @objc private func toggleTrayIcon(_ sender: NSMenuItem) {
        let current = settings.get(\.showTray)
        _ = settings.applyUpdate("showTray", value: !current)
        rebuildMenu()
    }

    @objc private func toggleShowSessionId(_ sender: NSMenuItem) {
        let current = settings.get(\.showSessionId)
        _ = settings.applyUpdate("showSessionId", value: !current)
        rebuildMenu()
    }

    @objc private func toggleStartOnLogin(_ sender: NSMenuItem) {
        let current = settings.get(\.openAtLogin)
        let newValue = !current
        let service = SMAppService.mainApp
        do {
            if newValue {
                try service.register()
            } else {
                try service.unregister()
            }
            _ = settings.applyUpdate("openAtLogin", value: newValue)
            logger.info("Login item \(newValue ? "registered" : "unregistered")")
        } catch {
            logger.error("Failed to \(newValue ? "register" : "unregister") login item: \(error)")
        }
        rebuildMenu()
    }

    @objc private func toggleStartWithClaude(_ sender: NSMenuItem) {
        let current = settings.get(\.autoStartWithClaude)
        _ = settings.applyUpdate("autoStartWithClaude", value: !current)
        rebuildMenu()
    }

    @objc private func openThemeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let themeDir = home.appendingPathComponent(".clawd/themes")
        try? FileManager.default.createDirectory(at: themeDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(themeDir)
    }

    @objc private func togglePetVisibility() {
        if let rw = renderWindowController?.window, let iw = inputWindowController?.window {
            if rw.isVisible {
                rw.orderOut(nil)
                iw.orderOut(nil)
            } else {
                rw.orderFront(nil)
                iw.orderFront(nil)
            }
        }
    }

    private func isDND() -> Bool {
        return cachedDND
    }

    private func rebuildMenu() {
        trayItem?.menu = buildMenu()
    }

    @objc private func checkForUpdates() {
        let i18n = I18n.shared
        UpdateChecker.shared.checkForUpdates(force: true) { release in
            if let release, UpdateChecker.shared.updateAvailable {
                let alert = NSAlert()
                alert.messageText = i18n.t("updateAvailable")
                alert.informativeText = i18n.t("updateAvailableMacMsg", ["version": release.version])
                alert.addButton(withTitle: i18n.t("download"))
                alert.addButton(withTitle: i18n.t("restartLater"))
                if alert.runModal() == .alertFirstButtonReturn {
                    UpdateChecker.shared.openDownloadPage()
                }
            } else {
                let alert = NSAlert()
                alert.messageText = i18n.t("updateNotAvailable")
                alert.informativeText = "v\(UpdateChecker.shared.currentVersion)"
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Single instance lock

    private func acquireInstanceLock() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let lockPath = "\(home)/.clawd/clawd-on-mac.lock"
        try? FileManager.default.createDirectory(atPath: "\(home)/.clawd", withIntermediateDirectories: true)

        lockFileDescriptor = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard lockFileDescriptor >= 0 else { return false }

        // Non-blocking exclusive lock
        if flock(lockFileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            close(lockFileDescriptor)
            lockFileDescriptor = -1
            return false
        }
        return true
    }

    private func releaseInstanceLock() {
        guard lockFileDescriptor >= 0 else { return }
        flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
    }

    // MARK: - Login item hydration

    private func hydrateLoginItemState() {
        let systemEnabled = SMAppService.mainApp.status == .enabled
        let prefEnabled = settings.get(\.openAtLogin)
        if systemEnabled != prefEnabled {
            _ = settings.applyUpdate("openAtLogin", value: systemEnabled)
            logger.info("Hydrated openAtLogin from system: \(systemEnabled)")
        }
        if !settings.get(\.openAtLoginHydrated) {
            _ = settings.applyUpdate("openAtLoginHydrated", value: true)
        }
    }

    // MARK: - Global hotkey

    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?

    private func setupGlobalHotkey() {
        // Cmd+Shift+Option+C to toggle pet visibility
        let mask: NSEvent.ModifierFlags = [.command, .shift, .option]
        // Global monitor: fires when app is NOT frontmost
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(mask),
                  event.charactersIgnoringModifiers?.lowercased() == "c" else { return }
            DispatchQueue.main.async {
                self?.togglePetVisibility()
            }
        }
        // Local monitor: fires when app IS frontmost
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(mask),
               event.charactersIgnoringModifiers?.lowercased() == "c" {
                DispatchQueue.main.async {
                    self?.togglePetVisibility()
                }
                return nil // consume the event
            }
            return event
        }
    }

    private func teardownGlobalHotkey() {
        if let monitor = globalHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalHotkeyMonitor = nil
        }
        if let monitor = localHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
            localHotkeyMonitor = nil
        }
    }
}