import AppKit
import os

private let logger = Logger(subsystem: "com.clawd.onmac", category: "InputWindowController")

class InputWindowController: NSWindowController {

    private let stateActor: PetStateActor
    var settings: SettingsController?
    private var lastMousePosition: CGPoint = .zero
    private var dragStartPosition: CGPoint = .zero
    private var isDragging: Bool = false
    private var clickCount: Int = 0
    private var lastClickTime: Date = Date.distantPast
    private var mouseOverPet: Bool = false
    private var firstClickDir: String? = nil
    private var clickTimer: DispatchWorkItem?
    private var isReacting: Bool = false

    private let CLICK_WINDOW_MS: TimeInterval = 0.4

    weak var renderWindowController: RenderWindowController?
    var miniModeController: MiniModeController?
    var bubbleManager: BubbleManager?

    init(stateActor: PetStateActor) {
        self.stateActor = stateActor

        let window = InputPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        setupWindow()
        setupTrackingArea()

        // Start pre-emptive hit checking for click-through
        (window as? InputPanel)?.startHitChecking()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWindow() {
        guard let window = window else { return }

        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating + 1
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isMovableByWindowBackground = false
        window.hidesOnDeactivate = false
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
    }

    private func setupTrackingArea() {
        guard let contentView = window?.contentView else { return }
        let area = NSTrackingArea(
            rect: contentView.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(area)
    }

    // MARK: - Mouse tracking for mini peek

    override func mouseEntered(with event: NSEvent) {
        mouseOverPet = true
        guard let mini = miniModeController, mini.miniMode, !mini.miniTransitioning else { return }

        if !mini.miniPeeked {
            mini.peekIn()
        }
    }

    override func mouseExited(with event: NSEvent) {
        mouseOverPet = false
        guard let mini = miniModeController, mini.miniMode else { return }

        if mini.miniPeeked {
            mini.peekOut()
        }
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        // In mini mode, double-click exits
        if let mini = miniModeController, mini.miniMode {
            if event.clickCount >= 2 {
                mini.exitMiniMode()
                return
            }
        }

        dragStartPosition = event.locationInWindow
        lastMousePosition = NSEvent.mouseLocation
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        // Block drag in mini mode or during transition
        if let mini = miniModeController, (mini.miniMode || mini.miniTransitioning) { return }

        let currentPos = NSEvent.mouseLocation
        let distance = hypot(currentPos.x - lastMousePosition.x, currentPos.y - lastMousePosition.y)

        if distance > 3 {
            if !isDragging {
                isDragging = true
                renderWindowController?.playReaction("drag")
            }
            moveWindowBy(deltaX: event.deltaX, deltaY: event.deltaY)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            if let mini = miniModeController {
                _ = mini.checkSnapOnDragEnd()
            }
        } else {
            handleClick(event)
        }
        isDragging = false
    }

    override func rightMouseUp(with event: NSEvent) {
        showContextMenu(at: event)
    }

    // MARK: - Click reaction logic (2-click = poke, 4-click = flail)

    private func handleClick(_ event: NSEvent) {
        guard !isReacting else { return }

        clickCount += 1
        if clickCount == 1 {
            let clickX = dragStartPosition.x
            let windowWidth = window?.frame.width ?? 50
            firstClickDir = clickX < windowWidth / 2 ? "left" : "right"
        }

        clickTimer?.cancel()

        if clickCount >= 4 {
            // 4+ clicks: flail (double/annoyed reaction with random files)
            clickCount = 0
            firstClickDir = nil
            playGatedReaction("double", duration: 3500)
        } else if clickCount >= 2 {
            // 2-3 clicks: wait for window, then poke or annoyed
            let timer = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.clickCount = 0

                // 50% chance of annoyed reaction
                if Bool.random() {
                    self.firstClickDir = nil
                    self.playGatedReaction("annoyed", duration: 3500)
                } else {
                    let dir = self.firstClickDir ?? "left"
                    self.firstClickDir = nil
                    self.playGatedReaction(dir == "left" ? "clickLeft" : "clickRight", duration: 2500)
                }
            }
            clickTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + CLICK_WINDOW_MS, execute: timer)
        } else {
            // 1 click: wait for window to see if more clicks come
            let timer = DispatchWorkItem { [weak self] in
                self?.clickCount = 0
                self?.firstClickDir = nil
            }
            clickTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + CLICK_WINDOW_MS, execute: timer)
        }
    }

    private func playGatedReaction(_ reaction: String, duration: Int) {
        isReacting = true
        renderWindowController?.playReaction(reaction)
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(duration) / 1000.0) { [weak self] in
            self?.isReacting = false
        }
    }

    // MARK: - Context menu (right-click on pet)

    private func showContextMenu(at event: NSEvent) {
        let menu = NSMenu()
        let i18n = I18n.shared
        let currentTheme = settings?.get(\.theme) ?? "clawd"
        let currentSize = settings?.get(\.size) ?? "P:12"

        // Size submenu
        let sizeMenu = NSMenu()
        for (label, value) in [
            ("P:8", "P:8"), ("P:10", "P:10"), ("P:12", "P:12"), ("P:15", "P:15")
        ] {
            let item = NSMenuItem(title: label, action: #selector(changeSize(_:)), keyEquivalent: "")
            item.representedObject = value
            item.target = self
            item.state = (currentSize == value) ? .on : .off
            sizeMenu.addItem(item)
        }
        let sizeItem = NSMenuItem(title: i18n.t("proportional"), action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(NSMenuItem.separator())

        // Mini mode
        let miniItem = NSMenuItem(
            title: miniModeController?.miniMode == true ? i18n.t("exitMiniMode") : i18n.t("miniMode"),
            action: #selector(toggleMiniFromContext),
            keyEquivalent: ""
        )
        miniItem.target = self
        menu.addItem(miniItem)

        menu.addItem(NSMenuItem.separator())

        // DND / Sleep
        let dndItem = NSMenuItem(
            title: i18n.t("sleep"),
            action: #selector(toggleDNDFromContext),
            keyEquivalent: ""
        )
        dndItem.target = self
        menu.addItem(dndItem)

        menu.addItem(NSMenuItem.separator())

        // Theme submenu
        let themeMenu = NSMenu()
        for (id, name) in [("clawd", "Clawd (Crab)"), ("calico", "Calico (Cat)")] {
            let item = NSMenuItem(title: name, action: #selector(changeTheme(_:)), keyEquivalent: "")
            item.representedObject = id
            item.target = self
            item.state = (currentTheme == id) ? .on : .off
            themeMenu.addItem(item)
        }
        let themeItem = NSMenuItem(title: i18n.t("theme"), action: nil, keyEquivalent: "")
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        // Display submenu (multi-monitor, only shown when >1 display)
        let displays = WindowSizeManager.availableDisplays()
        if displays.count > 1 {
            let displayMenu = NSMenu()
            for (i, display) in displays.enumerated() {
                let item = NSMenuItem(title: display.name, action: #selector(sendToDisplayFromContext(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                displayMenu.addItem(item)
            }
            let displayItem = NSMenuItem(title: i18n.t("sendToDisplay"), action: nil, keyEquivalent: "")
            displayItem.submenu = displayMenu
            menu.addItem(displayItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Settings
        let settingsItem = NSMenuItem(title: i18n.t("settings"), action: #selector(openSettingsFromContext), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: i18n.t("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: event.locationInWindow, in: window?.contentView)
    }

    @objc private func changeSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? String else { return }
        _ = settings?.applyUpdate("size", value: size)
    }

    @objc private func changeTheme(_ sender: NSMenuItem) {
        guard let themeId = sender.representedObject as? String else { return }
        _ = settings?.applyUpdate("theme", value: themeId)
    }

    @objc private func openSettingsFromContext() {
        NotificationCenter.default.post(name: .init("openPreferences"), object: nil)
    }

    @objc private func toggleMiniFromContext() {
        guard let mini = miniModeController else { return }
        if mini.miniMode {
            mini.exitMiniMode()
        } else {
            mini.enterViaMenu()
        }
    }

    @objc private func toggleDNDFromContext() {
        Task {
            await stateActor.toggleDoNotDisturb()
        }
    }

    @objc private func sendToDisplayFromContext(_ sender: NSMenuItem) {
        let displays = WindowSizeManager.availableDisplays()
        guard sender.tag < displays.count else { return }
        WindowSizeManager.sendToDisplay(
            displays[sender.tag].screen,
            renderWindow: renderWindowController?.window,
            inputWindow: window
        )
    }

    private func moveWindowBy(deltaX: CGFloat, deltaY: CGFloat) {
        guard let window = window else { return }
        var frame = window.frame
        frame.origin.x += deltaX
        frame.origin.y -= deltaY

        if let screen = window.screen ?? NSScreen.main {
            let wa = screen.visibleFrame
            frame.origin.y = max(wa.origin.y, min(wa.maxY - frame.height, frame.origin.y))
            frame.origin.x = max(wa.origin.x - frame.width * 0.5, min(wa.maxX - frame.width * 0.5, frame.origin.x))
        }

        window.setFrame(frame, display: true)

        // Sync render window position
        if let rw = renderWindowController?.window {
            var rwFrame = rw.frame
            rwFrame.origin = frame.origin
            rw.setFrame(rwFrame, display: true)
        }

        // Reposition bubbles to follow pet
        bubbleManager?.repositionAll(petFrame: frame)
    }

    func updateHitbox(for state: String, hitBox: HitBox) {
        guard let window = window else { return }

        var frame = window.frame
        let newWidth = hitBox.w * 2
        let newHeight = hitBox.h * 2

        frame.size.width = newWidth
        frame.size.height = newHeight
        frame.origin.x -= hitBox.x
        frame.origin.y -= hitBox.y

        window.setFrame(frame, display: true)
    }
}

class InputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Pet's clickable area in window coordinates (origin at bottom-left).
    var petHitRect: NSRect = .zero
    /// When true, accept clicks on entire window (skip hit-rect filtering).
    var isMiniMode: Bool = false

    private var hitCheckTimer: Timer?
    private var mouseInPetArea = false

    deinit {
        stopHitChecking()
    }

    func startHitChecking() {
        hitCheckTimer?.invalidate()
        hitCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.checkMousePosition()
        }
    }

    func stopHitChecking() {
        hitCheckTimer?.invalidate()
        hitCheckTimer = nil
    }

    private func checkMousePosition() {
        // Don't toggle during active mouse press (would interrupt drags)
        guard NSEvent.pressedMouseButtons == 0 else { return }

        // In mini mode, accept all events (entire window is the pet)
        if isMiniMode {
            if !mouseInPetArea {
                mouseInPetArea = true
                ignoresMouseEvents = false
            }
            return
        }

        let mouse = NSEvent.mouseLocation
        let wFrame = frame

        // petHitRect is in window coords (bottom-left origin); convert to screen
        let petScreenRect = NSRect(
            x: wFrame.origin.x + petHitRect.origin.x,
            y: wFrame.origin.y + petHitRect.origin.y,
            width: petHitRect.width,
            height: petHitRect.height
        )

        let inPet = !petHitRect.isEmpty && petScreenRect.contains(mouse)
        if inPet != mouseInPetArea {
            mouseInPetArea = inPet
            ignoresMouseEvents = !inPet
        }
    }
}