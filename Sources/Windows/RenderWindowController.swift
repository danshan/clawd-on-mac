import AppKit
import WebKit
import os

private let renderLogger = Logger(subsystem: "com.clawd.ClawdOnMac", category: "Render")

class RenderWindowController: NSWindowController {

    private var theme: Theme
    private let stateActor: PetStateActor
    private var themeLoader: ThemeLoader
    private var webView: WKWebView!
    private var currentState: String = "idle"
    private var themeName: String = "clawd"

    /// Called when a new SVG is loaded, with the SVG filename for hitbox updates.
    var onSVGLoaded: ((String) -> Void)?

    // Base HTML loaded flag — avoids full reload on every state change
    private var baseHTMLLoaded: Bool = false
    private var currentBaseURL: URL?
    private var pendingSVGPath: String?
    private var pendingSVGFilename: String?

    // Eye tracking state-awareness
    private var eyeTrackingEnabled: Bool = true
    private var eyeTrackingStates: Set<String> = ["idle", "dozing"]
    private var lastEyeX: CGFloat = 0
    private var lastEyeY: CGFloat = 0

    // Animation state
    private var isPlayingReaction: Bool = false
    private var idleAnimationTask: Task<Void, Never>?

    // Visual fallback chain for missing SVGs
    private let VISUAL_FALLBACK: [String: String] = [
        "error": "idle",
        "attention": "idle",
        "notification": "idle",
        "sweeping": "working",
        "carrying": "working",
        "juggling": "working"
    ]

    init(theme: Theme, stateActor: PetStateActor, themeLoader: ThemeLoader) {
        self.theme = theme
        self.stateActor = stateActor
        self.themeLoader = themeLoader
        self.themeName = themeLoader.directoryName(for: theme) ?? "clawd"

        if let eyeConfig = theme.eyeTracking {
            eyeTrackingEnabled = eyeConfig.enabled
            if let states = eyeConfig.states {
                eyeTrackingStates = Set(states)
            }
        }

        let window = RenderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 150, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        setupWindow()
        setupWebView()
        setupStateCallback()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        idleAnimationTask?.cancel()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeAllUserScripts()
        onSVGLoaded = nil
        cleanupTempFiles()
    }

    /// Clean up temp .clawd-shell.html files written during rendering.
    func cleanupTempFiles() {
        guard let baseURL = currentBaseURL else { return }
        let shellFile = baseURL.appendingPathComponent(".clawd-shell.html")
        if FileManager.default.fileExists(atPath: shellFile.path) {
            try? FileManager.default.removeItem(at: shellFile)
            renderLogger.debug("Cleaned up: \(shellFile.path, privacy: .public)")
        }
    }

    private func setupWindow() {
        guard let window = window else {
            renderLogger.error("window is nil")
            return
        }

        renderLogger.debug("Setting up window...")
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.acceptsMouseMovedEvents = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
    }

    private func setupWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        // CR-1: Block inline event handlers and external scripts via CSP.
        // Only allow scripts injected by our own shell HTML (nonce-based would be ideal
        // but WKWebView doesn't support CSP meta-tag nonce reliably; 'unsafe-inline' is
        // needed for our own <script> block, but we strip on* attributes via SVG sanitizer).
        let cspScript = WKUserScript(
            source: """
            var meta = document.createElement('meta');
            meta.httpEquiv = 'Content-Security-Policy';
            meta.content = "default-src 'none'; img-src file: data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; font-src file:";
            document.head.appendChild(meta);
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(cspScript)

        webView = WKWebView(frame: window!.contentView!.bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }

        window?.contentView?.addSubview(webView)
        webView.navigationDelegate = self
        loadSVG(for: "idle")
    }

    // MARK: - State change callback

    private func setupStateCallback() {
        Task {
            await stateActor.onStateChange = { [weak self] old, new in
                guard let self = self else { return }
                let stateName = new.rawValue.replacingOccurrences(of: "_", with: "-")
                DispatchQueue.main.async {
                    guard !self.isPlayingReaction else { return }
                    if stateName != self.currentState {
                        self.currentState = stateName
                        self.loadSVG(for: stateName)
                    }
                    NotificationCenter.default.post(name: .init("petStateChanged"), object: nil)
                }
            }
        }
    }

    // MARK: - SVG loading with tier + fallback

    func loadSVG(for state: String) {
        idleAnimationTask?.cancel()

        if state.hasPrefix("mini-") {
            if let path = themeLoader.getMiniStateSVG(for: state, themeName: themeName) {
                loadSVGFromPath(path)
            }
            return
        }

        // Working tier selection
        if state == "working" || state == "juggling" {
            Task {
                let count = await stateActor.getWorkingSessionCount()
                let path = resolveTierSVG(state: state, sessionCount: count)
                if let path = path {
                    await MainActor.run { loadSVGFromPath(path) }
                }
            }
            return
        }

        // Try direct state, then fallback chain
        if let path = themeLoader.getSVGPath(for: state, themeName: themeName) {
            loadSVGFromPath(path)
        } else if let fallback = VISUAL_FALLBACK[state],
                  let path = themeLoader.getSVGPath(for: fallback, themeName: themeName) {
            loadSVGFromPath(path)
        }

        // Start idle animation cycle if idle
        if state == "idle" {
            startIdleAnimationCycle()
        }
    }

    private func resolveTierSVG(state: String, sessionCount: Int) -> String? {
        let tiers = (state == "juggling") ? theme.jugglingTiers : theme.workingTiers
        guard let tiers = tiers, !tiers.isEmpty else {
            return themeLoader.getSVGPath(for: state, themeName: themeName)
        }

        // Pick the tier whose minSessions <= sessionCount (sorted desc)
        let sorted = tiers.sorted { $0.minSessions > $1.minSessions }
        for tier in sorted {
            if sessionCount >= tier.minSessions {
                if let resourcePath = Bundle.main.resourcePath {
                    for dir in ["assets/svg", "assets"] {
                        let path = resourcePath + "/themes/\(themeName)/\(dir)/\(tier.file)"
                        if FileManager.default.fileExists(atPath: path) {
                            return path
                        }
                    }
                }
            }
        }

        return themeLoader.getSVGPath(for: state, themeName: themeName)
    }

    // MARK: - Idle animation cycle

    private func startIdleAnimationCycle() {
        guard let animations = theme.idleAnimations, !animations.isEmpty else { return }

        idleAnimationTask = Task { [weak self] in
            // Wait before starting first idle animation
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
            guard !Task.isCancelled else { return }

            while !Task.isCancelled {
                guard let self = self, self.currentState == "idle" else { return }

                let anim = animations.randomElement()!
                if let resourcePath = Bundle.main.resourcePath {
                    let searchDirs = ["assets/svg", "assets"]
                    for dir in searchDirs {
                        let path = resourcePath + "/themes/\(self.themeName)/\(dir)/\(anim.file)"
                        if FileManager.default.fileExists(atPath: path) {
                            await MainActor.run { self.loadSVGFromPath(path) }
                            break
                        }
                    }
                }

                let durationNs = UInt64(anim.duration) * 1_000_000
                try? await Task.sleep(nanoseconds: durationNs)
                guard !Task.isCancelled else { return }

                // Return to base idle SVG
                await MainActor.run {
                    if let path = self.themeLoader.getSVGPath(for: "idle", themeName: self.themeName) {
                        self.loadSVGFromPath(path)
                    }
                }

                // Random pause before next animation
                let pauseMs = UInt64.random(in: 5000...15000)
                try? await Task.sleep(nanoseconds: pauseMs * 1_000_000)
            }
        }
    }

    private func loadSVGFromPath(_ path: String) {
        let fileURL = URL(fileURLWithPath: path)
        let dirURL = fileURL.deletingLastPathComponent()
        let ext = fileURL.pathExtension.lowercased()
        let filename = fileURL.lastPathComponent
        let isSVG = ext == "svg"

        // CR-8: If base HTML is loading, queue this and process in didFinish
        if !baseHTMLLoaded && currentBaseURL == dirURL {
            pendingSVGPath = path
            return
        }

        // If base HTML is already loaded and we're in the same directory, use JS swap
        if baseHTMLLoaded, currentBaseURL == dirURL {
            if isSVG {
                // Read SVG content, sanitize, and inject inline via JS
                if var svgContent = try? String(contentsOfFile: path, encoding: .utf8) {
                    svgContent = SVGSanitizer.sanitize(svgContent)
                    let escaped = svgContent
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "'", with: "\\'")
                        .replacingOccurrences(of: "\n", with: "\\n")
                        .replacingOccurrences(of: "\r", with: "")
                    let escapedFile = filename.replacingOccurrences(of: "'", with: "\\'")
                    webView.evaluateJavaScript("switchSVG('\(escaped)', '\(escapedFile)')", completionHandler: nil)
                }
            } else {
                let escapedFilename = filename.replacingOccurrences(of: "'", with: "\\'")
                webView.evaluateJavaScript("switchImg('\(escapedFilename)')", completionHandler: nil)
            }
            onSVGLoaded?(filename)
            return
        }

        // Full load: build shell HTML with inline SVG or <img>
        currentBaseURL = dirURL
        baseHTMLLoaded = false
        pendingSVGFilename = filename

        var svgInline = ""
        if isSVG {
            let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            svgInline = SVGSanitizer.sanitize(raw)
        }
        let imgSrc = isSVG ? "" : filename

        // Build objectScale config from theme
        let os = theme.objectScale
        let wr = os?.widthRatio ?? 1.9
        let hr = os?.heightRatio ?? 1.3
        let ox = os?.offsetX ?? -0.45
        let oy = os?.offsetY ?? -0.25
        let iwr = os?.imgWidthRatio ?? wr
        let objBot = os?.objBottom ?? (1 - (os?.offsetY ?? 0.25) - hr)
        let imgBot = os?.imgBottom ?? 0.05

        let fileScalesJSON = objectScaleFileScalesJSON()
        let fileOffsetsJSON = objectScaleFileOffsetsJSON()

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        html, body {
            width: 100%; height: 100%;
            overflow: hidden; background: transparent;
        }
        #pet-container {
            width: 100%; height: 100%;
            position: relative; overflow: hidden;
        }
        #svg-container {
            position: absolute; pointer-events: none;
            width: \(wr * 100)%; height: \(hr * 100)%;
            left: \(ox * 100)%; bottom: \(objBot * 100)%;
        }
        #svg-container svg {
            width: 100%; height: 100%;
        }
        #clawd-img {
            position: absolute; pointer-events: none;
            object-fit: contain; height: auto;
            width: \(iwr * 100)%;
            left: \((os?.imgOffsetX ?? ox) * 100)%;
            bottom: \(imgBot * 100)%;
            display: \(isSVG ? "none" : "block");
        }
        </style>
        </head>
        <body>
        <div id="pet-container">
            <div id="svg-container" style="display:\(isSVG ? "block" : "none")">\(svgInline)</div>
            <img id="clawd-img" src="\(imgSrc)">
        </div>
        <script>
        var _fileScales = \(fileScalesJSON);
        var _fileOffsets = \(fileOffsetsJSON);
        var _objScale = {
            width: \(wr * 100), height: \(hr * 100),
            left: \(ox * 100), objBottom: \(objBot * 100),
            imgWidth: \(iwr * 100), imgLeft: \((os?.imgOffsetX ?? ox) * 100),
            imgBottom: \(imgBot * 100)
        };

        \(eyeTrackingScript())

        function applyScale(el, file, isImg) {
            var fo = _fileOffsets[file] || {x:0, y:0};
            if (isImg) {
                var scale = _fileScales[file] || 1.0;
                el.style.width = (_objScale.imgWidth * scale) + '%';
                el.style.left = 'calc(' + _objScale.imgLeft + '% + ' + fo.x + 'px)';
                el.style.bottom = 'calc(' + _objScale.imgBottom + '% + ' + fo.y + 'px)';
            } else {
                el.style.width = _objScale.width + '%';
                el.style.height = _objScale.height + '%';
                el.style.left = 'calc(' + _objScale.left + '% + ' + fo.x + 'px)';
                el.style.bottom = 'calc(' + _objScale.objBottom + '% + ' + fo.y + 'px)';
            }
        }

        function switchSVG(svgContent, file) {
            var container = document.getElementById('svg-container');
            var img = document.getElementById('clawd-img');
            container.innerHTML = svgContent;
            container.style.display = 'block';
            img.style.display = 'none';
            if (file.indexOf('mini-') !== -1) {
                container.style.width = '100%';
                container.style.height = '100%';
                container.style.left = '0';
                container.style.bottom = '0';
            } else {
                applyScale(container, file, false);
            }
            setupEyeTracking();
        }

        function switchImg(filename) {
            var container = document.getElementById('svg-container');
            var img = document.getElementById('clawd-img');
            container.style.display = 'none';
            img.style.display = 'block';
            img.src = filename;
            applyScale(img, filename, true);
        }

        // Apply initial scale
        (function() {
            var file = '\(filename.replacingOccurrences(of: "'", with: "\\'"))';
            if (\(isSVG ? "true" : "false")) {
                applyScale(document.getElementById('svg-container'), file, false);
            } else {
                applyScale(document.getElementById('clawd-img'), file, true);
            }
        })();
        </script>
        </body>
        </html>
        """

        // Write to temp file for file:// origin (needed for <img> relative paths)
        let tempHTML = dirURL.appendingPathComponent(".clawd-shell.html")
        do {
            try html.write(to: tempHTML, atomically: true, encoding: .utf8)
            webView.loadFileURL(tempHTML, allowingReadAccessTo: dirURL)
        } catch {
            renderLogger.error("Failed to write shell HTML: \(error.localizedDescription, privacy: .public)")
            webView.loadHTMLString(html, baseURL: dirURL)
        }
    }

    // MARK: - ObjectScale JSON helpers

    private func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'", with: "\\'")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "")
    }

    private func objectScaleFileScalesJSON() -> String {
        guard let fs = theme.objectScale?.fileScales else { return "{}" }
        let pairs = fs.map { "\"\(jsEscape($0.key))\": \($0.value)" }
        return "{\(pairs.joined(separator: ", "))}"
    }

    private func objectScaleFileOffsetsJSON() -> String {
        guard let fo = theme.objectScale?.fileOffsets else { return "{}" }
        let pairs = fo.map { "\"\(jsEscape($0.key))\": {\"x\": \($0.value.x), \"y\": \($0.value.y)}" }
        return "{\(pairs.joined(separator: ", "))}"
    }

    private func eyeTrackingScript() -> String {
        let et = theme.eyeTracking
        let maxOffset = et?.maxOffset ?? 20.0

        // Multi-layer tracking (Calico-style)
        if let layers = et?.trackingLayers, !layers.isEmpty {
            return trackingLayersScript(layers: layers, globalMax: maxOffset)
        }

        // Simple ID-based tracking (Clawd-style)
        let eyeIds = et?.ids
        let bodyScale = et?.bodyScale ?? 0.33
        let shadowStretch = et?.shadowStretch ?? 0.15

        return """
        function setupEyeTracking() {
            var eyes = document.getElementById('\(eyeIds?.eyes ?? "eyes-js")');
            if (!eyes) return;
            window.clawdMouseTracker = {
                moveEye: function(dx, dy) {
                    var eyes = document.getElementById('\(eyeIds?.eyes ?? "eyes-js")');
                    if (eyes) eyes.setAttribute('transform', 'translate(' + dx + ',' + dy + ')');
                    var body = document.getElementById('\(eyeIds?.body ?? "body-js")');
                    if (body) body.setAttribute('transform', 'translate(' + (dx * \(bodyScale)) + ',' + (dy * \(bodyScale)) + ')');
                    var shadow = document.getElementById('\(eyeIds?.shadow ?? "shadow-js")');
                    if (shadow) shadow.setAttribute('transform', 'translate(' + (dx * \(shadowStretch)) + ',' + (dy * \(shadowStretch)) + ') scale(1,' + (1 + Math.abs(dy) * 0.02) + ')');
                }
            };
        }
        setupEyeTracking();
        """
    }

    private func trackingLayersScript(layers: [String: Theme.EyeTracking.TrackingLayer], globalMax: Double) -> String {
        // Build JS array of layer configs
        var layerConfigs: [String] = []
        for (_, layer) in layers.sorted(by: { $0.key < $1.key }) {
            let layerMax = layer.maxOffset ?? globalMax
            let ease = layer.ease ?? 0.15
            var idList: [String] = []
            if let ids = layer.ids { idList += ids.map { "'\(jsEscape($0))'" } }
            var classList: [String] = []
            if let classes = layer.classes { classList += classes.map { "'\(jsEscape($0))'" } }
            layerConfigs.append("{max: \(layerMax), ease: \(ease), ids: [\(idList.joined(separator: ","))], classes: [\(classList.joined(separator: ","))], wrappers: [], x: 0, y: 0}")
        }

        return """
        var _globalMax = \(globalMax);
        var _layerConfigs = [\(layerConfigs.joined(separator: ",\n"))];
        var _layerTargetDx = 0, _layerTargetDy = 0;
        var _layerAnimFrame = null;

        function _wrapEl(el) {
            if (!el) return null;
            var g = document.createElementNS('http://www.w3.org/2000/svg', 'g');
            g.setAttribute('data-tracking-wrapper', '1');
            el.parentNode.insertBefore(g, el);
            g.appendChild(el);
            return g;
        }

        function _initLayers() {
            for (var i = 0; i < _layerConfigs.length; i++) {
                var L = _layerConfigs[i];
                L.wrappers = [];
                for (var j = 0; j < L.ids.length; j++) {
                    var w = _wrapEl(document.getElementById(L.ids[j]));
                    if (w) L.wrappers.push(w);
                }
                for (var k = 0; k < L.classes.length; k++) {
                    var els = document.getElementsByClassName(L.classes[k]);
                    for (var m = 0; m < els.length; m++) {
                        var w2 = _wrapEl(els[m]);
                        if (w2) L.wrappers.push(w2);
                    }
                }
            }
        }

        function _animTick() {
            for (var i = 0; i < _layerConfigs.length; i++) {
                var L = _layerConfigs[i];
                var scale = L.max / (_globalMax || 20);
                var tx = _layerTargetDx * scale;
                var ty = _layerTargetDy * scale;
                L.x += (tx - L.x) * L.ease;
                L.y += (ty - L.y) * L.ease;
                if (Math.abs(L.x) < 0.01 && Math.abs(L.y) < 0.01 && tx === 0 && ty === 0) {
                    L.x = 0; L.y = 0;
                }
                var qx = Math.round(L.x * 4) / 4;
                var qy = Math.round(L.y * 4) / 4;
                for (var j = 0; j < L.wrappers.length; j++) {
                    L.wrappers[j].setAttribute('transform', 'translate(' + qx + ',' + qy + ')');
                }
            }
            _layerAnimFrame = requestAnimationFrame(_animTick);
        }

        function setupEyeTracking() {
            _initLayers();
            if (!_layerAnimFrame) _layerAnimFrame = requestAnimationFrame(_animTick);
            window.clawdMouseTracker = {
                moveEye: function(dx, dy) {
                    _layerTargetDx = dx;
                    _layerTargetDy = dy;
                }
            };
        }
        setupEyeTracking();
        """
    }

    // MARK: - Eye tracking

    func updateEyeTracking(position: CGPoint) {
        guard baseHTMLLoaded else { return }
        guard eyeTrackingEnabled else { return }
        guard eyeTrackingStates.contains(currentState) else { return }
        guard let windowRect = window?.frame else { return }

        let screenHeight = NSScreen.main?.frame.height ?? 0
        let petCenterX = windowRect.midX
        let petCenterY = screenHeight - windowRect.midY

        let dx = position.x - petCenterX
        let dy = position.y - petCenterY

        let distance = hypot(dx, dy)
        guard distance > 0 else { return }

        // Clamp to theme's global maxOffset
        let maxOffset = theme.eyeTracking?.maxOffset ?? 20.0
        let scale = min(maxOffset / distance, 1.0)
        let eyeX = dx * scale
        let eyeY = dy * scale

        let quantizedX = round(eyeX * 2) / 2
        let quantizedY = round(eyeY * 2) / 2

        // Skip JS eval if values unchanged
        guard quantizedX != lastEyeX || quantizedY != lastEyeY else { return }
        lastEyeX = quantizedX
        lastEyeY = quantizedY

        let js = "if (window.clawdMouseTracker) { window.clawdMouseTracker.moveEye(\(quantizedX), \(quantizedY)); }"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Reactions

    func playReaction(_ reaction: String) {
        guard !isPlayingReaction else { return }
        isPlayingReaction = true

        if let svgFile = themeLoader.getReactionSVG(for: reaction, themeName: themeName),
           let resourcePath = Bundle.main.resourcePath {
            var foundPath: String?
            for dir in ["assets/svg", "assets"] {
                let path = resourcePath + "/themes/\(themeName)/\(dir)/\(svgFile)"
                if FileManager.default.fileExists(atPath: path) {
                    foundPath = path
                    break
                }
            }
            if let path = foundPath {
                loadSVGFromPath(path)
            }

            let duration = theme.reactions?.duration(for: reaction) ?? 2500
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(duration) / 1000.0) { [weak self] in
                self?.isPlayingReaction = false
                self?.loadSVG(for: self?.currentState ?? "idle")
            }
        } else {
            isPlayingReaction = false
        }
    }

    // MARK: - Theme reload

    func reloadTheme(_ newTheme: Theme, loader: ThemeLoader) {
        theme = newTheme
        themeLoader = loader
        themeName = loader.directoryName(for: newTheme) ?? "clawd"
        baseHTMLLoaded = false
        currentBaseURL = nil

        if let eyeConfig = newTheme.eyeTracking {
            eyeTrackingEnabled = eyeConfig.enabled
            if let states = eyeConfig.states {
                eyeTrackingStates = Set(states)
            }
        }

        loadSVG(for: currentState)
    }

    func syncFromStateActor() {
        Task {
            let state = await stateActor.getCurrentDisplayState()
            let stateName = state.rawValue.replacingOccurrences(of: "_", with: "-")
            await MainActor.run {
                if stateName != self.currentState {
                    self.currentState = stateName
                    self.loadSVG(for: stateName)
                }
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension RenderWindowController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        baseHTMLLoaded = true
        renderLogger.info("Base HTML loaded, eye tracking ready")

        // Notify hitbox update for the initially loaded SVG
        if let fn = pendingSVGFilename {
            pendingSVGFilename = nil
            onSVGLoaded?(fn)
        }

        // CR-8: Process any SVG swap that was queued during load
        if let pending = pendingSVGPath {
            pendingSVGPath = nil
            loadSVGFromPath(pending)
        }
    }
}

class RenderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}