import AppKit
import os

private let logger = Logger(subsystem: "com.clawd.ClawdOnMac", category: "MouseTracker")

class MouseTracker {

    var onMouseMove: ((CGPoint) -> Void)?

    private var pollTimer: Timer?
    private var lastMousePosition: CGPoint = .zero
    private var isRunning: Bool = false

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Timer-based polling of NSEvent.mouseLocation at ~30fps
        // No permissions required — unlike CGEvent taps and NSEvent global
        // monitors which need Input Monitoring (kTCCServiceListenEvent)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let position = NSEvent.mouseLocation
            let screenHeight = NSScreen.main?.frame.height ?? 0
            let flipped = CGPoint(x: position.x, y: screenHeight - position.y)

            guard flipped != self.lastMousePosition else { return }
            self.lastMousePosition = flipped
            self.onMouseMove?(flipped)
        }
        logger.info("Mouse tracking started (polling, no permissions required)")
    }

    func stop() {
        guard isRunning else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        isRunning = false
    }

    deinit {
        stop()
    }
}