import AppKit
import os

private let logger = Logger(subsystem: "com.clawd.onmac", category: "SettingsWindow")

class SettingsWindowController: NSWindowController {

    private let settings: SettingsController
    private let stateActor: PetStateActor
    private let themeLoader: ThemeLoader

    private var languagePopup: NSPopUpButton?
    private var soundCheckbox: NSButton?
    private var launchAtLoginCheckbox: NSButton?
    private var subscriberToken: UUID?

    private let themeIds = ["clawd", "calico"]
    private let themeNames = ["Clawd (Crab)", "Calico (Cat)"]

    private let agentIds = AgentConfig.knownAgents
    private let agentNames = [
        "Claude Code", "Codex CLI", "Copilot CLI", "Cursor Agent",
        "Gemini CLI", "CodeBuddy", "Kiro CLI", "opencode"
    ]

    init(settings: SettingsController, stateActor: PetStateActor, themeLoader: ThemeLoader) {
        self.settings = settings
        self.stateActor = stateActor
        self.themeLoader = themeLoader

        let i18n = I18n.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = i18n.t("settings")
        window.center()

        super.init(window: window)
        setupUI()
        syncUI()

        subscriberToken = settings.subscribe { [weak self] _ in
            DispatchQueue.main.async { self?.syncUI() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    deinit {
        if let token = subscriberToken {
            settings.store.unsubscribe(token)
        }
    }

    // MARK: - Sync UI from settings

    private func syncUI() {
        let snap = settings.getSnapshot()

        let langIndex = ["en": 0, "zh": 1, "ko": 2]
        languagePopup?.selectItem(at: langIndex[snap.lang] ?? 0)
        soundCheckbox?.state = snap.soundMuted ? .off : .on
        launchAtLoginCheckbox?.state = snap.openAtLogin ? .on : .off
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        let i18n = I18n.shared

        let tabView = NSTabView(frame: contentView.bounds)
        tabView.autoresizingMask = [.width, .height]

        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = i18n.t("settingsGeneral")
        generalTab.view = createGeneralTab()
        tabView.addTabViewItem(generalTab)

        let themeTab = NSTabViewItem(identifier: "theme")
        themeTab.label = i18n.t("settingsTheme")
        themeTab.view = createThemeTab()
        tabView.addTabViewItem(themeTab)

        let agentsTab = NSTabViewItem(identifier: "agents")
        agentsTab.label = i18n.t("settingsAgents")
        agentsTab.view = createAgentsTab()
        tabView.addTabViewItem(agentsTab)

        let animTab = NSTabViewItem(identifier: "animations")
        animTab.label = "Animations"
        animTab.view = createAnimationsTab()
        tabView.addTabViewItem(animTab)

        contentView.addSubview(tabView)
    }

    private func createGeneralTab() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 350))
        let i18n = I18n.shared

        let languageLabel = NSTextField(labelWithString: i18n.t("settingsLanguage"))
        languageLabel.frame = NSRect(x: 20, y: 300, width: 100, height: 20)
        view.addSubview(languageLabel)

        let popup = NSPopUpButton(frame: NSRect(x: 130, y: 295, width: 150, height: 28))
        popup.addItems(withTitles: ["English", "中文", "한국어"])
        popup.target = self
        popup.action = #selector(languageChanged(_:))
        view.addSubview(popup)
        languagePopup = popup

        let soundLabel = NSTextField(labelWithString: i18n.t("settingsSound"))
        soundLabel.frame = NSRect(x: 20, y: 250, width: 100, height: 20)
        view.addSubview(soundLabel)

        let snd = NSButton(checkboxWithTitle: i18n.t("settingsSoundEnabled"), target: self, action: #selector(soundToggled(_:)))
        snd.frame = NSRect(x: 130, y: 248, width: 200, height: 20)
        view.addSubview(snd)
        soundCheckbox = snd

        let login = NSButton(checkboxWithTitle: i18n.t("settingsLaunchAtLogin"), target: self, action: #selector(launchAtLoginToggled(_:)))
        login.frame = NSRect(x: 20, y: 200, width: 300, height: 20)
        view.addSubview(login)
        launchAtLoginCheckbox = login

        return view
    }

    private func createThemeTab() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 350))
        let currentTheme = settings.get(\.theme)

        var yOffset: CGFloat = 300
        for (i, name) in themeNames.enumerated() {
            let radio = NSButton(radioButtonWithTitle: name, target: self, action: #selector(themeSelected(_:)))
            radio.frame = NSRect(x: 20, y: yOffset, width: 200, height: 20)
            radio.tag = i
            radio.state = (themeIds[i] == currentTheme) ? .on : .off
            view.addSubview(radio)
            yOffset -= 30
        }

        return view
    }

    private func createAgentsTab() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 350))
        let snap = settings.getSnapshot()

        // Column headers
        let enabledHeader = NSTextField(labelWithString: "Enabled")
        enabledHeader.frame = NSRect(x: 20, y: 320, width: 200, height: 16)
        enabledHeader.font = .systemFont(ofSize: 10, weight: .medium)
        enabledHeader.textColor = .secondaryLabelColor
        view.addSubview(enabledHeader)

        let permHeader = NSTextField(labelWithString: "Permissions")
        permHeader.frame = NSRect(x: 240, y: 320, width: 120, height: 16)
        permHeader.font = .systemFont(ofSize: 10, weight: .medium)
        permHeader.textColor = .secondaryLabelColor
        view.addSubview(permHeader)

        var yOffset: CGFloat = 295
        for (i, agentId) in agentIds.enumerated() {
            let name = (i < agentNames.count) ? agentNames[i] : agentId

            let checkbox = NSButton(checkboxWithTitle: name, target: self, action: #selector(agentToggled(_:)))
            checkbox.frame = NSRect(x: 20, y: yOffset, width: 200, height: 20)
            checkbox.tag = i
            checkbox.state = (snap.agents[agentId]?.enabled ?? true) ? .on : .off
            view.addSubview(checkbox)

            let permCheckbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(agentPermToggled(_:)))
            permCheckbox.frame = NSRect(x: 260, y: yOffset, width: 20, height: 20)
            permCheckbox.tag = i
            permCheckbox.state = (snap.agents[agentId]?.permissionsEnabled ?? true) ? .on : .off
            view.addSubview(permCheckbox)

            yOffset -= 30
        }

        return view
    }

    private func createAnimationsTab() -> NSView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 350))
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 600))

        let currentTheme = settings.get(\.theme)
        guard let theme = themeLoader.loadTheme(named: currentTheme) else {
            let label = NSTextField(labelWithString: "No theme loaded")
            label.frame = NSRect(x: 20, y: 320, width: 200, height: 20)
            contentView.addSubview(label)
            scrollView.documentView = contentView
            return scrollView
        }

        let wideSet = Set(theme.wideHitboxFiles ?? [])
        let sleepingSet = Set(theme.sleepingHitboxFiles ?? [])
        let states = theme.states.sorted(by: { $0.key < $1.key })

        var yOffset: CGFloat = CGFloat(states.count * 50 + 80)
        contentView.frame = NSRect(x: 0, y: 0, width: 460, height: yOffset + 20)

        // Header
        let header = NSTextField(labelWithString: "Theme: \(theme.name) — Animation States")
        header.frame = NSRect(x: 20, y: yOffset - 30, width: 400, height: 20)
        header.font = .boldSystemFont(ofSize: 13)
        contentView.addSubview(header)
        yOffset -= 50

        for (state, files) in states {
            let stateLabel = NSTextField(labelWithString: state)
            stateLabel.frame = NSRect(x: 20, y: yOffset, width: 100, height: 18)
            stateLabel.font = .systemFont(ofSize: 12, weight: .medium)
            contentView.addSubview(stateLabel)

            let fileNames = files.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            let fileLabel = NSTextField(labelWithString: fileNames)
            fileLabel.frame = NSRect(x: 130, y: yOffset, width: 240, height: 18)
            fileLabel.font = .systemFont(ofSize: 11)
            fileLabel.textColor = .secondaryLabelColor
            fileLabel.lineBreakMode = .byTruncatingTail
            contentView.addSubview(fileLabel)

            // Wide hitbox indicator
            let firstFile = (files.first as NSString?)?.lastPathComponent ?? ""
            if wideSet.contains(firstFile) {
                let badge = NSTextField(labelWithString: "W")
                badge.frame = NSRect(x: 380, y: yOffset, width: 20, height: 18)
                badge.font = .systemFont(ofSize: 10, weight: .bold)
                badge.textColor = .systemOrange
                badge.toolTip = "Wide hitbox"
                contentView.addSubview(badge)
            }
            if sleepingSet.contains(firstFile) {
                let badge = NSTextField(labelWithString: "S")
                badge.frame = NSRect(x: 400, y: yOffset, width: 20, height: 18)
                badge.font = .systemFont(ofSize: 10, weight: .bold)
                badge.textColor = .systemBlue
                badge.toolTip = "Sleeping hitbox"
                contentView.addSubview(badge)
            }

            yOffset -= 40
        }

        // Open theme folder button
        yOffset -= 10
        let openButton = NSButton(title: "Open Theme Folder…", target: self, action: #selector(openThemeFolder))
        openButton.frame = NSRect(x: 20, y: max(yOffset, 10), width: 180, height: 28)
        openButton.bezelStyle = .rounded
        contentView.addSubview(openButton)

        scrollView.documentView = contentView
        return scrollView
    }

    // MARK: - Actions

    @objc private func openThemeFolder() {
        let currentTheme = settings.get(\.theme)
        let themesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawd/themes/\(currentTheme)")
        if FileManager.default.fileExists(atPath: themesDir.path) {
            NSWorkspace.shared.open(themesDir)
        } else if let bundlePath = Bundle.main.resourcePath {
            let bundleTheme = URL(fileURLWithPath: bundlePath)
                .appendingPathComponent("themes/\(currentTheme)")
            NSWorkspace.shared.open(bundleTheme)
        }
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let langMap = ["English": "en", "中文": "zh", "한국어": "ko"]
        if let title = sender.selectedItem?.title, let lang = langMap[title] {
            _ = settings.applyUpdate("lang", value: lang)
        }
    }

    @objc private func soundToggled(_ sender: NSButton) {
        _ = settings.applyUpdate("soundMuted", value: sender.state == .off)
    }

    @objc private func launchAtLoginToggled(_ sender: NSButton) {
        _ = settings.applyUpdate("openAtLogin", value: sender.state == .on)
    }

    @objc private func themeSelected(_ sender: NSButton) {
        let idx = sender.tag
        guard idx >= 0 && idx < themeIds.count else { return }
        _ = settings.applyUpdate("theme", value: themeIds[idx])
    }

    @objc private func agentToggled(_ sender: NSButton) {
        let idx = sender.tag
        guard idx >= 0 && idx < agentIds.count else { return }
        let agentId = agentIds[idx]
        var agents = settings.get(\.agents)
        agents[agentId]?.enabled = (sender.state == .on)
        _ = settings.applyUpdate("agents", value: agents)
    }

    @objc private func agentPermToggled(_ sender: NSButton) {
        let idx = sender.tag
        guard idx >= 0 && idx < agentIds.count else { return }
        let agentId = agentIds[idx]
        var agents = settings.get(\.agents)
        agents[agentId]?.permissionsEnabled = (sender.state == .on)
        _ = settings.applyUpdate("agents", value: agents)
    }
}