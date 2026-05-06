import AppKit
import WebKit
import os

private let logger = Logger(subsystem: "com.clawd.ClawdOnMac", category: "DashboardPanel")

/// Dashboard window controller using standard macOS NSWindow.
class DashboardPanelController: NSObject {

    private var window: NSWindow?
    private var webView: WKWebView?
    private var settingsSubscriptionId: UUID?

    private let defaultWidth: CGFloat = 1100
    private let defaultHeight: CGFloat = 780

    private weak var statusItem: NSStatusItem?
    private weak var settings: SettingsController?

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    init(statusItem: NSStatusItem?, settings: SettingsController? = nil) {
        self.statusItem = statusItem
        self.settings = settings
        super.init()
        subscribeToSettings()
    }

    deinit {
        if let id = settingsSubscriptionId {
            settings?.store.unsubscribe(id)
        }
    }

    // MARK: - Settings Subscription

    private func subscribeToSettings() {
        guard let settings = settings else { return }
        settingsSubscriptionId = settings.subscribe { [weak self] broadcast in
            self?.pushSettingsChange(broadcast.changes, snapshot: broadcast.snapshot)
        }
    }

    private func pushSettingsChange(_ changes: [String: Any], snapshot: PreferencesSnapshot) {
        guard let webView = webView, isVisible else { return }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(snapshot),
              let json = String(data: data, encoding: .utf8) else { return }
        let changedKeys = Array(changes.keys)
        guard let keysData = try? JSONSerialization.data(withJSONObject: changedKeys),
              let keysJson = String(data: keysData, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            webView.evaluateJavaScript(
                "window.onSettingsChanged && window.onSettingsChanged(\(json), \(keysJson))"
            )
        }
    }

    // MARK: - Window Setup

    private func createWindowIfNeeded() {
        guard window == nil else { return }

        let frame = NSRect(x: 0, y: 0, width: defaultWidth, height: defaultHeight)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let win = NSWindow(
            contentRect: frame,
            styleMask: styleMask,
            backing: .buffered,
            defer: true
        )

        win.title = "Clawd Dashboard"
        win.titleVisibility = .visible
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.fullScreenAuxiliary]
        win.delegate = self

        // Size constraints
        win.minSize = NSSize(width: 600, height: 450)

        setupWebView(in: win)

        self.window = win
    }

    private func setupWebView(in win: NSWindow) {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(WeakMessageHandler(self), name: "dashboard")
        configuration.userContentController = contentController
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: win.contentView!.bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        win.contentView?.addSubview(webView)

        self.webView = webView
    }

    // MARK: - Show / Hide

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        createWindowIfNeeded()
        guard let win = window else { return }

        loadDashboardContent()

        // Make app visible in CMD+Tab while dashboard is open
        // Workaround: transitioning through .prohibited forces macOS to re-evaluate
        NSApp.setActivationPolicy(.prohibited)
        NSApp.setActivationPolicy(.regular)
        // Explicitly set dock icon (needed after runtime policy switch)
        if let icon = Self.loadAppIcon() {
            NSApp.applicationIconImage = icon
        }

        if !win.isVisible {
            win.center()
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
        restoreActivationPolicyIfNeeded()
    }

    func showAtRoute(_ route: String) {
        show()
        navigateTo(route)
    }

    func navigateTo(_ route: String) {
        webView?.evaluateJavaScript("window.navigateTo && window.navigateTo('\(route)')")
    }

    // MARK: - Content Loading

    private var serverPort: Int = 23333

    func setServerPort(_ port: Int) {
        self.serverPort = port
    }

    private func loadDashboardContent() {
        guard let webView = webView else { return }
        if webView.url == nil {
            let url = URL(string: "http://localhost:\(serverPort)/dashboard")!
            webView.load(URLRequest(url: url))
        }
    }
}

// MARK: - NSWindowDelegate

extension DashboardPanelController: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        restoreActivationPolicyIfNeeded()
    }
}

// MARK: - Private Helpers

private extension DashboardPanelController {

    func restoreActivationPolicyIfNeeded() {
        // Only revert to .accessory if user hasn't enabled "Show in Dock"
        let showDock = settings?.get(\.showDock) ?? false
        if !showDock {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    static func loadAppIcon() -> NSImage? {
        // Try asset catalog first
        if let icon = NSImage(named: "AppIcon") {
            return icon
        }
        // Fallback: use the system icon for our own bundle
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }
}

// MARK: - WKScriptMessageHandler

extension DashboardPanelController: WKScriptMessageHandler {

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "dashboard",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        logger.debug("Dashboard bridge message: \(type)")

        switch type {
        case "settings.get":
            handleSettingsGet()
        case "settings.update":
            handleSettingsUpdate(body)
        case "settings.command", "command":
            handleSettingsCommand(body)
        case "skills.syncAll":
            handleSkillsSyncAll(body)
        case "skills.unsyncAll":
            handleSkillsUnsyncAll(body)
        default:
            logger.warning("Unknown dashboard message type: \(type)")
        }
    }

    // MARK: - Settings Bridge Handlers

    private func handleSettingsGet() {
        guard let settings = settings else { return }
        let snapshot = settings.getSnapshot()
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(snapshot),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(
                "window.onSettingsLoaded && window.onSettingsLoaded(\(json))"
            )
        }
    }

    private func handleSettingsUpdate(_ body: [String: Any]) {
        guard let settings = settings,
              let key = body["key"] as? String,
              let value = body["value"] else { return }
        let result = settings.applyUpdate(key, value: value)
        if result.status == .error {
            logger.warning("Settings update failed for key '\(key)': \(result.message ?? "")")
        }
    }

    private func handleSettingsCommand(_ body: [String: Any]) {
        guard let name = body["name"] as? String else { return }

        // Handle local commands that don't go through SettingsController
        if name == "openThemeFolder" {
            DispatchQueue.main.async {
                let home = FileManager.default.homeDirectoryForCurrentUser
                let themeDir = home.appendingPathComponent(".clawd/themes")
                try? FileManager.default.createDirectory(at: themeDir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(themeDir)
            }
            return
        }

        guard let settings = settings else { return }
        let payload = body["payload"]
        Task {
            let result = await settings.applyCommand(name, payload: payload)
            if result.status == .error {
                logger.warning("Settings command '\(name)' failed: \(result.message ?? "")")
            }
        }
    }

    private func handleSkillsSyncAll(_ body: [String: Any]) {
        guard let toolKey = body["toolKey"] as? String else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let appDelegate = NSApp.delegate as? AppDelegate
                let sm = try SkillsManager()
                let result = try sm.syncAllSkillsToTool(toolKey: toolKey)
                let encoder = JSONEncoder()
                if let data = try? encoder.encode(result),
                   let json = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self.webView?.evaluateJavaScript(
                            "window.onBulkSyncResult && window.onBulkSyncResult(\(json), 'sync')"
                        )
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.webView?.evaluateJavaScript(
                        "window.onBulkSyncResult && window.onBulkSyncResult({error:'\(error.localizedDescription)'}, 'sync')"
                    )
                }
            }
        }
    }

    private func handleSkillsUnsyncAll(_ body: [String: Any]) {
        guard let toolKey = body["toolKey"] as? String else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let sm = try SkillsManager()
                let result = try sm.unsyncAllSkillsFromTool(toolKey: toolKey)
                let encoder = JSONEncoder()
                if let data = try? encoder.encode(result),
                   let json = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self.webView?.evaluateJavaScript(
                            "window.onBulkSyncResult && window.onBulkSyncResult(\(json), 'unsync')"
                        )
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.webView?.evaluateJavaScript(
                        "window.onBulkSyncResult && window.onBulkSyncResult({error:'\(error.localizedDescription)'}, 'unsync')"
                    )
                }
            }
        }
    }
}

// MARK: - Weak Message Handler (prevents retain cycles)

private class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(_ delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
