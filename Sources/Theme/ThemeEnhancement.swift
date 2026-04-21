import Foundation
import os

// MARK: - SVG Sanitizer

/// Strips dangerous elements and attributes from SVG content.
struct SVGSanitizer {

    static let DANGEROUS_TAGS: Set<String> = [
        "script", "foreignobject", "iframe", "embed", "object", "applet",
        "meta", "link", "base", "form", "input", "textarea", "button"
    ]

    static let DANGEROUS_ATTR_PREFIX = "on"
    static let DANGEROUS_HREF_PATTERN = "javascript:"

    /// Sanitize SVG content by removing dangerous tags and attributes.
    /// Returns sanitized content, or nil if parsing fails.
    static func sanitize(_ content: String) -> String {
        var result = content

        // Remove dangerous tags — loop until no more matches to handle nesting
        for tag in DANGEROUS_TAGS {
            let openClose = "<\(tag)[^>]*>.*?</\(tag)>"
            let selfClose = "<\(tag)[^>]*/>"
            let closingOnly = "</\(tag)\\s*>"

            for pattern in [openClose, selfClose, closingOnly] {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
                var prev = ""
                while prev != result {
                    prev = result
                    result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
                }
            }
        }

        // Remove on* event attributes (quoted and unquoted values)
        if let regex = try? NSRegularExpression(pattern: "\\s+on\\w+\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)", options: [.caseInsensitive]) {
            var prev = ""
            while prev != result {
                prev = result
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
            }
        }

        // Whitelist approach for href/xlink:href: only allow internal anchors (#...)
        // Unquoted alternative excluded — SVG attributes are always quoted in practice.
        if let regex = try? NSRegularExpression(pattern: "(?:xlink:)?href\\s*=\\s*(?:\"(?!#)[^\"]*\"|'(?!#)[^']*')", options: [.caseInsensitive]) {
            var prev = ""
            while prev != result {
                prev = result
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
            }
        }

        // Remove data: URIs (potential XSS via data:text/html)
        if let regex = try? NSRegularExpression(pattern: "(?:xlink:)?href\\s*=\\s*(?:\"data:[^\"]*\"|'data:[^']*')", options: [.caseInsensitive]) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        // Strip CDATA sections that could contain script
        if let regex = try? NSRegularExpression(pattern: "<!\\[CDATA\\[.*?\\]\\]>", options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        return result
    }
}

// MARK: - Theme variant support

/// Allowed keys a variant may override.
let VARIANT_ALLOWED_KEYS: Set<String> = [
    "viewBox", "layout", "eyeTracking", "states", "workingTiers", "jugglingTiers",
    "idleAnimations", "displayHintMap", "timings", "hitBoxes", "wideHitboxFiles",
    "sleepingHitboxFiles", "reactions", "miniMode", "sounds", "objectScale"
]

// MARK: - Theme file monitor

/// Watches a directory for changes and fires a callback.
private let logger = Logger(subsystem: "com.clawd.onmac", category: "ThemeFileMonitor")

class ThemeFileMonitor {

    private var source: DispatchSourceFileSystemObject?
    private var directoryFD: Int32 = -1
    var onChange: (() -> Void)?

    func start(directory: String) {
        stop()

        // Ensure directory exists before monitoring
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        directoryFD = open(directory, O_EVTONLY)
        guard directoryFD >= 0 else {
            logger.error("Failed to open directory: \(directory, privacy: .public)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryFD,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.onChange?()
        }

        let fd = self.directoryFD
        source.setCancelHandler { [weak self] in
            if fd >= 0 { close(fd) }
            self?.directoryFD = -1
        }

        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit {
        stop()
    }
}

// MARK: - Theme sub-struct defaults

extension Theme.ThemeTimings {

    static let defaults = Theme.ThemeTimings(
        minDisplay: nil,
        autoReturn: nil,
        yawnDuration: 5000,
        wakeDuration: 2000,
        deepSleepTimeout: 300_000,
        mouseIdleTimeout: 120_000,
        mouseSleepTimeout: 180_000
    )

    func withDefaults() -> Theme.ThemeTimings {
        Theme.ThemeTimings(
            minDisplay: minDisplay,
            autoReturn: autoReturn,
            yawnDuration: yawnDuration ?? 5000,
            wakeDuration: wakeDuration ?? 2000,
            deepSleepTimeout: deepSleepTimeout ?? 300_000,
            mouseIdleTimeout: mouseIdleTimeout ?? 120_000,
            mouseSleepTimeout: mouseSleepTimeout ?? 180_000
        )
    }
}

extension Theme.ObjectScale {

    static let defaults = Theme.ObjectScale(
        widthRatio: 1.0,
        heightRatio: 1.0,
        offsetX: 0,
        offsetY: 0,
        imgWidthRatio: nil,
        imgOffsetX: nil,
        objBottom: nil,
        imgBottom: nil,
        fileScales: nil,
        fileOffsets: nil
    )

    func withDefaults() -> Theme.ObjectScale {
        Theme.ObjectScale(
            widthRatio: widthRatio ?? 1.0,
            heightRatio: heightRatio ?? 1.0,
            offsetX: offsetX ?? 0,
            offsetY: offsetY ?? 0,
            imgWidthRatio: imgWidthRatio,
            imgOffsetX: imgOffsetX,
            objBottom: objBottom,
            imgBottom: imgBottom,
            fileScales: fileScales,
            fileOffsets: fileOffsets
        )
    }
}

// MARK: - Theme defaults cascade

extension Theme {

    /// Apply default values for all optional sub-structs.
    func withDefaults() -> Theme {
        Theme(
            schemaVersion: schemaVersion,
            name: name,
            author: author,
            version: version,
            description: description,
            viewBox: viewBox,
            layout: layout,
            eyeTracking: eyeTracking,
            states: states,
            workingTiers: workingTiers,
            jugglingTiers: jugglingTiers,
            idleAnimations: idleAnimations,
            displayHintMap: displayHintMap,
            timings: (timings ?? ThemeTimings.defaults).withDefaults(),
            hitBoxes: hitBoxes,
            wideHitboxFiles: wideHitboxFiles,
            sleepingHitboxFiles: sleepingHitboxFiles,
            reactions: reactions,
            miniMode: miniMode,
            sounds: sounds,
            objectScale: (objectScale ?? ObjectScale.defaults).withDefaults(),
            transitions: transitions
        )
    }
}
