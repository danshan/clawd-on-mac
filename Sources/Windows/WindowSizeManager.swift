import AppKit

/// Manages proportional pet sizing and multi-display positioning.
class WindowSizeManager {

    // MARK: - Proportional sizing

    /// Standard size presets as percentage of display long edge.
    static let presets: [(label: String, ratio: CGFloat)] = [
        ("P:8", 8), ("P:10", 10), ("P:12", 12), ("P:15", 15)
    ]

    private static let PORTRAIT_BOOST: CGFloat = 1.6
    private static let PORTRAIT_MAX_WIDTH_RATIO: CGFloat = 0.6

    /// Pet hit rect as fractions of window dimensions (bottom-left origin).
    /// bottomRatio: fraction from bottom where hitbox starts.
    /// topRatio: fraction from bottom where hitbox ends.
    static var hitBottomRatio: CGFloat = 0.0
    static var hitTopRatio: CGFloat = 1.0

    /// Compute hit rect ratios from theme data (viewBox + layout + hitBox).
    static func computeHitRatios(from theme: Theme, hitBox: HitBox? = nil) {
        guard let viewBox = theme.viewBox,
              let layout = theme.layout,
              let contentBox = layout.contentBox,
              contentBox.height > 0,
              viewBox.height > 0 else {
            hitBottomRatio = 0.0
            hitTopRatio = 1.0
            return
        }

        let hb = hitBox
            ?? theme.hitBoxes?["default"]
            ?? HitBox(x: -1, y: 5, w: 17, h: 12)

        let vhr = CGFloat(layout.visibleHeightRatio ?? 0.58)
        let bbr = CGFloat(layout.baselineBottomRatio ?? 0.05)
        let baselineY = CGFloat(layout.baselineY ?? 17)
        let vbY = CGFloat(viewBox.y)
        let vbH = CGFloat(viewBox.height)
        let cbH = CGFloat(contentBox.height)

        let unitRatio = vhr / cbH
        let layoutHeightRatio = vbH * unitRatio
        let layoutBottomRatio = bbr - (vbY + vbH - baselineY) * unitRatio

        // artRect.y in CG-fraction (0=top, 1=bottom, relative to window)
        let artTopFrac = 1 - layoutHeightRatio - layoutBottomRatio
        let scaleY = layoutHeightRatio / vbH

        let hbY = CGFloat(hb.y)
        let hbH = CGFloat(hb.h)

        // CG fractions (from top of window)
        let hitTopCG = artTopFrac + (hbY - vbY) * scaleY
        let hitBotCG = artTopFrac + (hbY - vbY + hbH) * scaleY

        // Convert to NSWindow fractions (from bottom of window) + add padding
        let padding: CGFloat = 0.04
        hitBottomRatio = max(0, (1 - hitBotCG) - padding)
        hitTopRatio = min(1, (1 - hitTopCG) + padding)
    }

    /// Compute pixel size from proportional ratio and work area.
    static func proportionalPixelSize(ratio: CGFloat, workArea: NSRect) -> NSSize {
        let safeRatio = ratio.isFinite ? ratio : 10
        let w = workArea.width
        let h = workArea.height
        let basePx = max(w, h)
        var px = round(basePx * safeRatio / 100)

        // Portrait boost: tall displays get a larger pet
        if h > w && w > 0 {
            let boosted = round(px * PORTRAIT_BOOST)
            let maxPortrait = round(w * PORTRAIT_MAX_WIDTH_RATIO)
            px = min(boosted, maxPortrait)
        }

        return NSSize(width: px, height: px)
    }

    /// Parse size string "P:<ratio>" → ratio, or nil for legacy format.
    static func parseRatio(from sizeString: String) -> CGFloat? {
        guard sizeString.hasPrefix("P:") else { return nil }
        let numStr = String(sizeString.dropFirst(2))
        return Double(numStr).map { CGFloat($0) }
    }

    /// Resize render + input windows to proportional size on given screen.
    static func applySize(
        _ sizeString: String,
        renderWindow: NSWindow?,
        inputWindow: NSWindow?,
        screen: NSScreen? = nil
    ) {
        guard let rw = renderWindow else { return }
        let targetScreen = screen ?? rw.screen ?? NSScreen.main
        guard let wa = targetScreen?.visibleFrame else { return }

        guard let ratio = parseRatio(from: sizeString) else { return }
        let newSize = proportionalPixelSize(ratio: ratio, workArea: wa)

        var frame = rw.frame
        // Keep bottom-left origin, resize
        frame.size = newSize
        rw.setFrame(frame, display: true)

        if let iw = inputWindow {
            var iFrame = iw.frame
            iFrame.origin = frame.origin
            iFrame.size = newSize
            iw.setFrame(iFrame, display: true)

            if let panel = iw as? InputPanel {
                let h = newSize.height
                let y0 = h * hitBottomRatio
                let y1 = h * hitTopRatio
                panel.petHitRect = NSRect(
                    x: 0, y: y0,
                    width: newSize.width,
                    height: y1 - y0
                )
            }
        }
    }

    // MARK: - Multi-display

    /// Move pet to a specific display.
    static func sendToDisplay(
        _ display: NSScreen,
        renderWindow: NSWindow?,
        inputWindow: NSWindow?
    ) {
        guard let rw = renderWindow else { return }
        let wa = display.visibleFrame
        let size = rw.frame.size

        // Position at bottom-right of target display
        let x = wa.maxX - size.width - 20
        let y = wa.origin.y + 20

        var frame = rw.frame
        frame.origin = CGPoint(x: x, y: y)
        rw.setFrame(frame, display: true)

        if let iw = inputWindow {
            var iFrame = iw.frame
            iFrame.origin = frame.origin
            iFrame.size = size
            iw.setFrame(iFrame, display: true)

            if let panel = iw as? InputPanel {
                let h = size.height
                let y0 = h * hitBottomRatio
                let y1 = h * hitTopRatio
                panel.petHitRect = NSRect(
                    x: 0, y: y0,
                    width: size.width,
                    height: y1 - y0
                )
            }
        }
    }

    /// Update petHitRect on InputPanel using current hitBottomRatio/hitTopRatio.
    static func updatePetHitRect(inputWindow: NSWindow?) {
        guard let iw = inputWindow, let panel = iw as? InputPanel else { return }
        let h = iw.frame.size.height
        let y0 = h * hitBottomRatio
        let y1 = h * hitTopRatio
        panel.petHitRect = NSRect(
            x: 0, y: y0,
            width: iw.frame.size.width,
            height: y1 - y0
        )
    }

    /// Get display names for multi-display menu.
    static func availableDisplays() -> [(name: String, screen: NSScreen)] {
        return NSScreen.screens.enumerated().map { (i, screen) in
            let name = screen.localizedName
            return (name: name.isEmpty ? "Display \(i + 1)" : name, screen: screen)
        }
    }
}

// MARK: - Display change observer

class DisplayChangeObserver {

    var onDisplayChanged: (() -> Void)?
    var onDisplayRemoved: (() -> Void)?

    func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayConfigChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func displayConfigChanged() {
        onDisplayChanged?()
    }
}
