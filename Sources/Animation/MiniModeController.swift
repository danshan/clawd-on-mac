import AppKit

// MARK: - Mini mode animation controller

/// Manages mini mode transitions: edge snap, crabwalk entry, peek animations,
/// parabolic jump entry/exit, and re-snap prevention.
class MiniModeController {

    // MARK: - Constants

    private let PEEK_OFFSET: CGFloat = 25
    private let SNAP_TOLERANCE: CGFloat = 30
    private let JUMP_PEAK_HEIGHT: CGFloat = 40
    private let JUMP_DURATION: TimeInterval = 0.350
    private let CRABWALK_SPEED: CGFloat = 0.12  // px/ms

    // MARK: - State

    private(set) var miniMode: Bool = false
    private(set) var miniEdge: Edge = .right
    private(set) var miniTransitioning: Bool = false
    private(set) var miniPeeked: Bool = false
    private(set) var miniSleepPeeked: Bool = false

    private var preMiniFrame: NSRect = .zero
    private var offsetRatio: CGFloat = 0.25  // from theme

    private var animationTimer: Timer?
    private var transitionClearTask: DispatchWorkItem?

    enum Edge {
        case left, right
    }

    // MARK: - Injected references

    weak var renderWindow: NSWindow?
    weak var inputWindow: NSWindow?
    var stateActor: PetStateActor?
    var onMiniStateChanged: ((Bool) -> Void)?

    deinit {
        cancelAll()
    }

    // MARK: - Configuration

    func configure(offsetRatio: CGFloat) {
        self.offsetRatio = offsetRatio
    }

    // MARK: - Edge snap detection (called on drag end)

    func checkSnapOnDragEnd() -> Bool {
        guard !miniMode, !miniTransitioning else { return false }
        guard let window = renderWindow, let screen = window.screen ?? NSScreen.main else { return false }

        let wa = screen.visibleFrame
        let bounds = window.frame
        let size = bounds.size
        let mEdge = round(size.width * offsetRatio)

        let rightLimit = wa.maxX - size.width + mEdge
        if bounds.origin.x >= rightLimit - SNAP_TOLERANCE {
            enterMiniMode(workArea: wa, edge: .right)
            return true
        }

        let leftLimit = wa.origin.x - mEdge
        if bounds.origin.x <= leftLimit + SNAP_TOLERANCE {
            enterMiniMode(workArea: wa, edge: .left)
            return true
        }

        return false
    }

    // MARK: - Enter via menu (crabwalk → snap)

    func enterViaMenu() {
        guard !miniMode, !miniTransitioning else { return }
        guard let window = renderWindow, let screen = window.screen ?? NSScreen.main else { return }

        miniTransitioning = true
        preMiniFrame = window.frame
        let wa = screen.visibleFrame
        let bounds = window.frame

        // Determine nearest edge
        let centerX = bounds.midX
        let waMidX = wa.midX
        let edge: Edge = centerX >= waMidX ? .right : .left
        miniEdge = edge

        let size = bounds.size
        let targetX: CGFloat
        if edge == .right {
            targetX = wa.maxX - size.width + round(size.width * offsetRatio)
        } else {
            targetX = wa.origin.x - round(size.width * offsetRatio)
        }

        let distance = abs(bounds.origin.x - targetX)
        let durationMs = distance / CRABWALK_SPEED
        let duration = TimeInterval(durationMs) / 1000.0

        // Crabwalk to edge
        animateWindowX(
            from: bounds.origin.x,
            to: targetX,
            duration: max(duration, 0.2)
        ) { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.miniMode = true

                Task { [weak self] in
                    await self?.stateActor?.setMiniMode(true)
                    await MainActor.run {
                        self?.onMiniStateChanged?(true)
                    }
                }

                self.scheduleTransitionClear(delay: 0.5)
            }
        }
    }

    // MARK: - Enter mini mode (direct snap)

    func enterMiniMode(workArea wa: NSRect, edge: Edge) {
        guard let window = renderWindow else { return }

        miniTransitioning = true
        preMiniFrame = window.frame
        miniEdge = edge
        miniMode = true

        let size = window.frame.size
        let miniX = calcMiniX(workArea: wa, size: size)
        var frame = window.frame
        frame.origin.x = miniX
        window.setFrame(frame, display: true)
        syncInputWindow()

        Task { [weak self] in
            await self?.stateActor?.setMiniMode(true)
            await MainActor.run {
                self?.onMiniStateChanged?(true)
            }
        }

        scheduleTransitionClear(delay: 0.3)
    }

    // MARK: - Exit mini mode (parabolic jump back)

    func exitMiniMode() {
        guard miniMode, !miniTransitioning else { return }
        guard let window = renderWindow, let screen = window.screen ?? NSScreen.main else { return }

        miniTransitioning = true
        let wa = screen.visibleFrame
        let size = window.frame.size
        let mEdge = round(size.width * offsetRatio)

        // Clamp pre-mini position to prevent re-snap
        var targetX = preMiniFrame.origin.x
        let targetY = preMiniFrame.origin.y

        // Re-snap prevention: push 100px inward from edge
        let rightLimit = wa.maxX - size.width + mEdge - SNAP_TOLERANCE
        if targetX >= rightLimit - SNAP_TOLERANCE {
            targetX = wa.maxX - size.width + mEdge - 100
        }

        let leftLimit = wa.origin.x - mEdge + SNAP_TOLERANCE
        if targetX <= leftLimit + SNAP_TOLERANCE {
            targetX = wa.origin.x - mEdge + SNAP_TOLERANCE + 100
        }

        // Clamp to screen bounds
        let clampedX = max(wa.origin.x, min(wa.maxX - size.width, targetX))
        let clampedY = max(wa.origin.y, min(wa.maxY - size.height, targetY))

        let startX = window.frame.origin.x
        let startY = window.frame.origin.y

        animateWindowParabola(
            from: CGPoint(x: startX, y: startY),
            to: CGPoint(x: clampedX, y: clampedY),
            duration: JUMP_DURATION
        ) { [weak self] in
            guard let self = self else { return }
            self.miniMode = false
            self.miniPeeked = false
            self.miniSleepPeeked = false
            self.miniTransitioning = false

            Task { [weak self] in
                await self?.stateActor?.setMiniMode(false)
                await MainActor.run {
                    self?.onMiniStateChanged?(false)
                }
            }
        }
    }

    // MARK: - Peek animations

    func peekIn() {
        guard miniMode, !miniTransitioning else { return }
        guard let window = renderWindow else { return }

        let offset: CGFloat = (miniEdge == .left) ? PEEK_OFFSET : -PEEK_OFFSET
        let startX = window.frame.origin.x
        let targetX = startX + offset

        animateWindowX(from: startX, to: targetX, duration: 0.2) { [weak self] in
            self?.miniPeeked = true
        }
    }

    func peekOut() {
        guard miniMode, miniPeeked else { return }
        guard let window = renderWindow else { return }

        let offset: CGFloat = (miniEdge == .left) ? -PEEK_OFFSET : PEEK_OFFSET
        let startX = window.frame.origin.x
        let targetX = startX + offset

        animateWindowX(from: startX, to: targetX, duration: 0.2) { [weak self] in
            self?.miniPeeked = false
        }
    }

    // MARK: - Helpers

    private func calcMiniX(workArea wa: NSRect, size: NSSize) -> CGFloat {
        if miniEdge == .left {
            return wa.origin.x - round(size.width * offsetRatio)
        }
        return wa.maxX - round(size.width * (1 - offsetRatio))
    }

    private func syncInputWindow() {
        guard let rw = renderWindow, let iw = inputWindow else { return }
        var frame = iw.frame
        frame.origin = rw.frame.origin
        iw.setFrame(frame, display: true)
    }

    private func scheduleTransitionClear(delay: TimeInterval) {
        transitionClearTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.miniTransitioning = false
        }
        transitionClearTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    // MARK: - Window animations

    /// Linear horizontal animation with ease-out-quad.
    private func animateWindowX(
        from startX: CGFloat,
        to targetX: CGFloat,
        duration: TimeInterval,
        onDone: @escaping () -> Void
    ) {
        animationTimer?.invalidate()
        let startTime = CACurrentMediaTime()

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - startTime
            let t = min(elapsed / duration, 1.0)
            let eased = t * (2 - t)  // ease-out-quad

            let x = round(startX + (targetX - startX) * eased)
            if let window = self.renderWindow {
                var frame = window.frame
                frame.origin.x = x
                window.setFrame(frame, display: false)
                self.syncInputWindow()
            }

            if t >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil
                onDone()
            }
        }
    }

    /// Parabolic arc animation with ease-out-quad.
    private func animateWindowParabola(
        from start: CGPoint,
        to target: CGPoint,
        duration: TimeInterval,
        onDone: @escaping () -> Void
    ) {
        animationTimer?.invalidate()
        let startTime = CACurrentMediaTime()
        let peakHeight = JUMP_PEAK_HEIGHT

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - startTime
            let t = min(elapsed / duration, 1.0)
            let eased = t * (2 - t)

            let x = round(start.x + (target.x - start.x) * eased)
            let arc = -4 * peakHeight * t * (t - 1)
            let y = round(start.y + (target.y - start.y) * eased + arc)

            if let window = self.renderWindow {
                var frame = window.frame
                frame.origin.x = x
                frame.origin.y = y
                window.setFrame(frame, display: false)
                self.syncInputWindow()
            }

            if t >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil
                onDone()
            }
        }
    }

    // MARK: - Display change handling

    func handleDisplayChange() {
        guard miniMode else { return }
        guard let window = renderWindow, let screen = window.screen ?? NSScreen.main else { return }

        let wa = screen.visibleFrame
        let size = window.frame.size
        let miniX = calcMiniX(workArea: wa, size: size)

        var frame = window.frame
        frame.origin.x = miniX
        frame.origin.y = max(wa.origin.y, min(wa.maxY - size.height, frame.origin.y))
        window.setFrame(frame, display: true)
        syncInputWindow()
    }

    func cancelAll() {
        animationTimer?.invalidate()
        animationTimer = nil
        transitionClearTask?.cancel()
        miniTransitioning = false
    }
}
