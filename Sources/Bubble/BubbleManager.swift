import AppKit
import WebKit

// MARK: - Weak script message handler wrapper

private class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(controller, didReceive: message)
    }
}

// MARK: - Permission entry

struct PermissionEntry {
    let sessionId: String
    let toolName: String
    let toolInput: [String: Any]?
    let suggestions: [[String: String]]
    let rawSuggestions: [[String: Any]]
    let agentId: String
    let isElicitation: Bool
    let createdAt: Date
    var resolved: Bool = false
    var resolvedSuggestion: String?
}

// MARK: - Bubble window

class BubbleWindowController: NSWindowController {

    private(set) var webView: WKWebView!
    private var permission: PermissionEntry?
    private var onResponse: ((String) -> Void)?
    private var previousApp: NSRunningApplication?

    var hasPermission: Bool { permission != nil && !permission!.resolved }
    var currentAgentId: String? { permission?.agentId }

    init() {
        let window = BubblePanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        setupWindow()
        setupWebView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.navigationDelegate = nil
        onResponse = nil
    }

    private func setupWindow() {
        guard let window = window else { return }
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating + 2
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let contentController = WKUserContentController()
        contentController.add(WeakScriptMessageHandler(self), name: "bubbleAction")
        config.userContentController = contentController

        guard let window = window, let contentView = window.contentView else { return }
        webView = WKWebView(frame: contentView.bounds, configuration: config)
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        contentView.addSubview(webView)
    }

    func showPermission(_ entry: PermissionEntry, relativeTo petFrame: NSRect, onResponse: @escaping (String) -> Void) {
        self.permission = entry
        self.onResponse = onResponse
        self.previousApp = NSWorkspace.shared.frontmostApplication

        let html = buildPermissionHTML(entry)
        webView.loadHTMLString(html, baseURL: nil)

        // Position above the pet
        guard let window = window else { return }
        let bubbleWidth: CGFloat = entry.isElicitation ? 360 : 320
        let bubbleHeight: CGFloat = entry.isElicitation ? 400 : 200
        let x = petFrame.midX - bubbleWidth / 2
        let y = petFrame.maxY + 10

        window.setFrame(NSRect(x: x, y: y, width: bubbleWidth, height: bubbleHeight), display: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showNotification(_ text: String, relativeTo petFrame: NSRect, duration: TimeInterval = 5.0) {
        let html = buildNotificationHTML(text)
        webView.loadHTMLString(html, baseURL: nil)

        guard let window = window else { return }
        let x = petFrame.midX - 160
        let y = petFrame.maxY + 10
        window.setFrame(NSRect(x: x, y: y, width: 320, height: 80), display: true)
        window.orderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.dismiss()
        }
    }

    func dismiss() {
        window?.orderOut(nil)
        if let prev = previousApp {
            prev.activate()
        }
        permission = nil
        onResponse = nil
        previousApp = nil
    }

    func reposition(relativeTo petFrame: NSRect) {
        guard let window = window, window.isVisible else { return }
        var frame = window.frame
        frame.origin.x = petFrame.midX - frame.width / 2
        frame.origin.y = petFrame.maxY + 10
        window.setFrame(frame, display: false)
    }

    // MARK: - HTML builders

    private func htmlEscape(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
           .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func buildPermissionHTML(_ entry: PermissionEntry) -> String {
        if entry.isElicitation {
            return buildElicitationHTML(entry)
        }
        let toolDisplay = htmlEscape(entry.toolName)
        let inputDisplay: String
        if let input = entry.toolInput {
            if let jsonData = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                inputDisplay = htmlEscape(jsonStr)
            } else {
                inputDisplay = input.map { "\(htmlEscape($0.key)): \(htmlEscape(String(describing: $0.value)))" }.joined(separator: "\n")
            }
        } else {
            inputDisplay = ""
        }
        let escapedTool = toolDisplay.replacingOccurrences(of: "'", with: "\\'")
        let escapedInput = inputDisplay
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")

        var suggestionsHTML = ""
        for (index, suggestion) in entry.suggestions.enumerated() {
            if let label = suggestion["label"] {
                suggestionsHTML += "<button class='suggestion' onclick=\"respond(&#39;suggestion:\(index)&#39;)\">\(htmlEscape(label))</button>"
            }
        }

        return """
        <!DOCTYPE html>
        <html>
        <head><style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 12px;
               background: rgba(30,30,30,0.95); color: #e0e0e0; border-radius: 12px;
               padding: 12px; overflow: hidden; -webkit-user-select: none; }
        .tool { font-weight: 600; color: #7eb8ff; margin-bottom: 6px; }
        .input { font-family: 'SF Mono', monospace; font-size: 10px; color: #aaa;
                 white-space: pre-wrap; max-height: 60px; overflow-y: auto; margin-bottom: 8px;
                 padding: 4px; background: rgba(0,0,0,0.3); border-radius: 4px; }
        .actions { display: flex; gap: 6px; flex-wrap: wrap; }
        button { padding: 4px 12px; border-radius: 6px; border: 1px solid #555; background: #333;
                 color: #e0e0e0; cursor: pointer; font-size: 11px; }
        button:hover { background: #444; }
        button.allow { background: #2d6a2d; border-color: #3a8a3a; }
        button.deny { background: #6a2d2d; border-color: #8a3a3a; }
        .suggestion { background: #2d4a6a; border-color: #3a6a8a; }
        </style></head>
        <body>
        <div class='tool'>\(escapedTool)</div>
        <div class='input'>\(escapedInput)</div>
        <div class='actions'>
          <button class='allow' onclick="respond('allow')">Allow</button>
          <button class='deny' onclick="respond('deny')">Deny</button>
          \(suggestionsHTML)
        </div>
        <script>
        function respond(action) {
          window.webkit.messageHandlers.bubbleAction.postMessage(action);
        }
        </script>
        </body></html>
        """
    }

    private func buildElicitationHTML(_ entry: PermissionEntry) -> String {
        // Extract questions from toolInput
        var questionsJSON = "[]"
        if let input = entry.toolInput,
           let questions = input["questions"] as? [[String: Any]],
           let data = try? JSONSerialization.data(withJSONObject: questions),
           let str = String(data: data, encoding: .utf8) {
            questionsJSON = str
        }

        return """
        <!DOCTYPE html>
        <html>
        <head><style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 12px;
               background: rgba(30,30,30,0.95); color: #e0e0e0; border-radius: 12px;
               padding: 12px; overflow-y: auto; -webkit-user-select: none; }
        .question-card { margin-bottom: 10px; padding: 8px; background: rgba(0,0,0,0.3); border-radius: 6px; }
        .question-header { font-weight: 600; color: #7eb8ff; margin-bottom: 4px; font-size: 11px; }
        .question-text { color: #ccc; margin-bottom: 6px; }
        .question-hint { color: #888; font-size: 10px; margin-bottom: 4px; }
        .option-item { display: flex; align-items: center; gap: 6px; padding: 3px 0; cursor: pointer; }
        .option-item:hover { color: #fff; }
        .option-label { font-size: 11px; }
        .option-desc { font-size: 10px; color: #888; margin-left: 4px; }
        .actions { display: flex; gap: 6px; margin-top: 8px; }
        button { padding: 4px 12px; border-radius: 6px; border: 1px solid #555; background: #333;
                 color: #e0e0e0; cursor: pointer; font-size: 11px; }
        button:hover { background: #444; }
        button.allow { background: #2d6a2d; border-color: #3a8a3a; }
        button.allow:disabled { opacity: 0.5; cursor: not-allowed; }
        button.deny { background: #6a2d2d; border-color: #8a3a3a; }
        </style></head>
        <body>
        <div id="form"></div>
        <div class="actions">
          <button class="allow" id="submitBtn" disabled onclick="submitAnswers()">Submit</button>
          <button class="deny" onclick="respond('deny')">Dismiss</button>
        </div>
        <script>
        const questions = \(questionsJSON);
        const formEl = document.getElementById('form');
        const submitBtn = document.getElementById('submitBtn');

        questions.forEach((q, qi) => {
          const card = document.createElement('div');
          card.className = 'question-card';
          card.innerHTML = `<div class="question-header">Question ${qi + 1}</div>
            <div class="question-text">${esc(q.question || '')}</div>
            <div class="question-hint">${q.multiSelect ? 'Choose one or more' : 'Choose one'}</div>`;
          const options = Array.isArray(q.options) ? q.options : [];
          options.forEach((opt, oi) => {
            const label = document.createElement('label');
            label.className = 'option-item';
            const input = document.createElement('input');
            input.type = q.multiSelect ? 'checkbox' : 'radio';
            input.name = 'q' + qi;
            input.value = opt.label || '';
            input.onchange = updateSubmit;
            const span = document.createElement('span');
            span.className = 'option-label';
            span.textContent = opt.label || '';
            label.appendChild(input);
            label.appendChild(span);
            if (opt.description) {
              const desc = document.createElement('span');
              desc.className = 'option-desc';
              desc.textContent = opt.description;
              label.appendChild(desc);
            }
            card.appendChild(label);
          });
          formEl.appendChild(card);
        });

        function esc(s) { return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }

        function updateSubmit() {
          const allAnswered = questions.every((q, qi) => {
            return formEl.querySelectorAll('input[name=q' + qi + ']:checked').length > 0;
          });
          submitBtn.disabled = !allAnswered;
        }

        function submitAnswers() {
          const answers = {};
          questions.forEach((q, qi) => {
            const checked = [...formEl.querySelectorAll('input[name=q' + qi + ']:checked')];
            answers[q.question] = checked.map(c => c.value).join(', ');
          });
          window.webkit.messageHandlers.bubbleAction.postMessage(JSON.stringify({
            type: 'elicitation-submit', answers: answers
          }));
        }

        function respond(action) {
          window.webkit.messageHandlers.bubbleAction.postMessage(action);
        }
        </script>
        </body></html>
        """
    }

    private func buildNotificationHTML(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!DOCTYPE html>
        <html>
        <head><style>
        * { margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 12px;
               background: rgba(30,30,30,0.9); color: #e0e0e0; border-radius: 10px;
               padding: 10px; -webkit-user-select: none; }
        </style></head>
        <body>\(escaped)</body></html>
        """
    }
}

extension BubbleWindowController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "bubbleAction" else { return }
        if let action = message.body as? String {
            // Try parsing as JSON for elicitation submit
            if let data = action.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let type = json["type"] as? String, type == "elicitation-submit",
               let answers = json["answers"] as? [String: String] {
                onResponse?("elicitation-submit:\(action)")
            } else {
                onResponse?(action)
            }
            dismiss()
        }
    }
}

class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Bubble manager

class BubbleManager {

    private var activeBubbles: [String: BubbleWindowController] = [:]  // keyed by sessionId
    private var notificationTimers: [String: DispatchWorkItem] = [:]
    var followPet: Bool = true
    private var permissionHotkeyMonitor: Any?

    deinit {
        if let monitor = permissionHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        notificationTimers.values.forEach { $0.cancel() }
    }

    /// Show a permission bubble for a session.
    func showPermission(
        _ entry: PermissionEntry,
        petFrame: NSRect,
        onResponse: @escaping (String) -> Void
    ) {
        // Cancel any existing notification timer for this session
        notificationTimers[entry.sessionId]?.cancel()
        notificationTimers.removeValue(forKey: entry.sessionId)

        let bubble = getOrCreateBubble(sessionId: entry.sessionId)
        bubble.showPermission(entry, relativeTo: petFrame, onResponse: { [weak self] action in
            onResponse(action)
            self?.activeBubbles.removeValue(forKey: entry.sessionId)
            self?.syncPermissionHotkeys()
        })
        syncPermissionHotkeys()
    }

    /// Show a notification bubble.
    func showNotification(_ text: String, sessionId: String, petFrame: NSRect, duration: TimeInterval = 5.0) {
        // Cancel any existing timer for this session
        notificationTimers[sessionId]?.cancel()

        let bubble = getOrCreateBubble(sessionId: sessionId)
        bubble.showNotification(text, relativeTo: petFrame, duration: duration)

        let timer = DispatchWorkItem { [weak self] in
            self?.activeBubbles.removeValue(forKey: sessionId)
            self?.notificationTimers.removeValue(forKey: sessionId)
        }
        notificationTimers[sessionId] = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: timer)
    }

    /// Reposition all active bubbles relative to pet.
    func repositionAll(petFrame: NSRect) {
        guard followPet else { return }
        var offset: CGFloat = 0
        for (_, bubble) in activeBubbles {
            var adjustedFrame = petFrame
            adjustedFrame.origin.y += offset
            bubble.reposition(relativeTo: adjustedFrame)
            offset += 90  // stack vertically
        }
    }

    /// Dismiss all active bubbles.
    func dismissAll() {
        for (_, bubble) in activeBubbles {
            bubble.dismiss()
        }
        activeBubbles.removeAll()
        for (_, timer) in notificationTimers { timer.cancel() }
        notificationTimers.removeAll()
        syncPermissionHotkeys()
    }

    /// Dismiss bubbles belonging to a specific agent.
    func dismissBubbles(forAgent agentId: String) {
        let matching = activeBubbles.filter { $0.value.currentAgentId == agentId }
        for (sessionId, bubble) in matching {
            bubble.dismiss()
            activeBubbles.removeValue(forKey: sessionId)
            notificationTimers[sessionId]?.cancel()
            notificationTimers.removeValue(forKey: sessionId)
        }
        if !matching.isEmpty {
            syncPermissionHotkeys()
        }
    }

    // MARK: - Permission hotkeys (Cmd+Shift+Y = Allow, Cmd+Shift+N = Deny)

    private func syncPermissionHotkeys() {
        let hasActiveBubble = activeBubbles.values.contains { $0.hasPermission }
        if hasActiveBubble && permissionHotkeyMonitor == nil {
            permissionHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let mask = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard mask == [.command, .shift] else { return }
                let key = event.charactersIgnoringModifiers?.lowercased()
                if key == "y" {
                    DispatchQueue.main.async { self?.respondToFrontBubble("allow") }
                } else if key == "n" {
                    DispatchQueue.main.async { self?.respondToFrontBubble("deny") }
                }
            }
        } else if !hasActiveBubble, let monitor = permissionHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
            permissionHotkeyMonitor = nil
        }
    }

    private func respondToFrontBubble(_ action: String) {
        guard action == "allow" || action == "deny" else { return }
        guard let (_, bubble) = activeBubbles.first(where: { $0.value.hasPermission }) else { return }
        bubble.webView?.evaluateJavaScript("respond('\(action)')") { _, _ in }
    }

    private func getOrCreateBubble(sessionId: String) -> BubbleWindowController {
        if let existing = activeBubbles[sessionId] {
            return existing
        }
        let bubble = BubbleWindowController()
        activeBubbles[sessionId] = bubble
        return bubble
    }
}
