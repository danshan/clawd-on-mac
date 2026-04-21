import Foundation
import os

struct HitBox: Codable, Sendable {
    let x: Double, y: Double, w: Double, h: Double
}

struct Theme: Codable {
    let schemaVersion: Int
    let name: String
    let author: String?
    let version: String?
    let description: String?

    let viewBox: ViewBox?
    let layout: Layout?
    let eyeTracking: EyeTracking?
    let states: [String: [String]]
    let workingTiers: [WorkingTier]?
    let jugglingTiers: [WorkingTier]?
    let idleAnimations: [IdleAnimation]?
    let displayHintMap: [String: String]?
    let timings: ThemeTimings?
    let hitBoxes: [String: HitBox]?
    let wideHitboxFiles: [String]?
    let sleepingHitboxFiles: [String]?
    let reactions: Reactions?
    let miniMode: MiniModeConfig?
    let sounds: Sounds?
    let objectScale: ObjectScale?
    let transitions: [String: TransitionConfig]?

    struct TransitionConfig: Codable {
        let `in`: Int?
        let out: Int?
    }

    struct ViewBox: Codable {
        let x: Double, y: Double, width: Double, height: Double
    }

    struct Layout: Codable {
        let contentBox: ContentBox?
        let centerX: Double?
        let baselineY: Double?
        let visibleHeightRatio: Double?
        let baselineBottomRatio: Double?

        struct ContentBox: Codable {
            let x: Double, y: Double, width: Double, height: Double
        }
    }

    struct EyeTracking: Codable {
        let enabled: Bool
        let states: [String]?
        let eyeRatioX: Double?
        let eyeRatioY: Double?
        let maxOffset: Double?
        let bodyScale: Double?
        let shadowStretch: Double?
        let shadowShift: Double?
        let ids: EyeIds?
        let shadowOrigin: String?
        let trackingLayers: [String: TrackingLayer]?

        struct EyeIds: Codable {
            let eyes: String?
            let body: String?
            let shadow: String?
            let dozeEyes: String?
        }

        struct TrackingLayer: Codable {
            let ids: [String]?
            let classes: [String]?
            let maxOffset: Double?
            let ease: Double?
        }
    }

    struct WorkingTier: Codable {
        let minSessions: Int
        let file: String
    }

    struct IdleAnimation: Codable {
        let file: String
        let duration: Int
    }

    struct ThemeTimings: Codable {
        let minDisplay: [String: Int]?
        let autoReturn: [String: Int]?
        let yawnDuration: Int?
        let wakeDuration: Int?
        let deepSleepTimeout: Int?
        let mouseIdleTimeout: Int?
        let mouseSleepTimeout: Int?
    }

    struct Reactions: Codable {
        let drag: ReactionDef?
        let clickLeft: ReactionDef?
        let clickRight: ReactionDef?
        let annoyed: ReactionDef?
        let double: ReactionDef?

        struct ReactionDef: Codable {
            let file: String?
            let files: [String]?
            let duration: Int?
        }

        func duration(for reaction: String) -> Int {
            let def: ReactionDef? = switch reaction {
            case "drag": drag
            case "clickLeft": clickLeft
            case "clickRight": clickRight
            case "annoyed": annoyed
            case "double": double
            default: nil
            }
            return def?.duration ?? 2500
        }
    }

    struct MiniModeConfig: Codable {
        let supported: Bool?
        let offsetRatio: Double?
        let states: [String: [String]]?
        let timings: MiniTimings?
        let glyphFlips: GlyphFlips?

        struct MiniTimings: Codable {
            let minDisplay: [String: Int]?
            let autoReturn: [String: Int]?
        }

        struct GlyphFlips: Codable {
            let pixel_z: Int?
            let pixel_z_small: Int?
        }
    }

    struct Sounds: Codable {
        let complete: String?
        let confirm: String?
    }

    struct ObjectScale: Codable {
        let widthRatio: Double?
        let heightRatio: Double?
        let offsetX: Double?
        let offsetY: Double?
        let imgWidthRatio: Double?
        let imgOffsetX: Double?
        let objBottom: Double?
        let imgBottom: Double?
        let fileScales: [String: Double]?
        let fileOffsets: [String: FileOffset]?

        struct FileOffset: Codable {
            let x: Double
            let y: Double
        }
    }
}

private let logger = Logger(subsystem: "com.clawd.onmac", category: "ThemeLoader")

/// Fields replaced wholesale during variant merge (arrays with positional semantics).
private let VARIANT_REPLACE_FIELDS: Set<String> = [
    "workingTiers", "jugglingTiers", "idleAnimations",
    "wideHitboxFiles", "sleepingHitboxFiles", "displayHintMap"
]

class ThemeLoader {

    private var themes: [String: Theme] = [:]
    private var currentTheme: Theme?

    /// Path to the user themes directory (for hot-reload monitoring).
    var themesDirectory: String {
        getUserThemesPath()
    }

    func loadDefaultTheme() -> Theme? {
        logger.debug("Loading default theme...")
        return loadTheme(named: "clawd") ?? loadTheme(named: "calico")
    }

    func loadTheme(named name: String, variant: String? = nil) -> Theme? {
        // Validate theme name to prevent path traversal
        let validName = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !name.isEmpty,
              name.unicodeScalars.allSatisfy({ validName.contains($0) }) else {
            logger.error("Invalid theme name rejected: \(name, privacy: .public)")
            return nil
        }

        let resolvedVariant = variant ?? resolveVariantFromPrefs(themeName: name)
        let cacheKey = themeCacheKey(name: name, variant: resolvedVariant)

        if let cached = themes[cacheKey] {
            logger.debug("Theme '\(cacheKey, privacy: .public)' found in cache")
            return cached
        }

        guard let resourcePath = Bundle.main.resourcePath else {
            logger.error("Bundle.main.resourcePath is nil")
            return nil
        }

        logger.debug("resourcePath: \(resourcePath, privacy: .public)")
        let bundledPath = resourcePath + "/themes/\(name)/theme.json"
        let userPath = getUserThemesPath() + "/\(name)/theme.json"
        let resolvedUserPath = (userPath as NSString).resolvingSymlinksInPath
        let themesBase = (getUserThemesPath() as NSString).resolvingSymlinksInPath + "/"
        logger.debug("bundledPath: \(bundledPath, privacy: .public)")
        logger.debug("userPath: \(userPath, privacy: .public)")

        var theme: Theme?

        if let loaded = loadThemeWithVariant(path: bundledPath, variant: resolvedVariant) {
            theme = loaded
        } else if resolvedUserPath.hasPrefix(themesBase),
                  let loaded = loadThemeWithVariant(path: userPath, variant: resolvedVariant) {
            theme = loaded
        }

        if let t = theme {
            themes[cacheKey] = t
            currentTheme = t
        }

        return theme
    }

    // MARK: - Theme loading pipeline

    private func loadThemeWithVariant(path: String, variant: String?) -> Theme? {
        guard var raw = loadRawThemeDict(path: path) else { return nil }

        raw = migrateThemeDict(raw)

        if let variantId = variant {
            raw = resolveAndApplyVariant(raw: raw, variantId: variantId)
        }

        // Strip "variants" key — not part of Theme struct
        raw.removeValue(forKey: "variants")

        guard let data = try? JSONSerialization.data(withJSONObject: raw) else {
            logger.error("Failed to re-serialize theme dict at \(path, privacy: .public)")
            return nil
        }

        do {
            let theme = try JSONDecoder().decode(Theme.self, from: data)
            return theme.withDefaults()
        } catch {
            logger.error("Failed to decode theme at \(path, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }

    private func loadRawThemeDict(path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            logger.error("Theme file is not a valid JSON object: \(path, privacy: .public)")
            return nil
        }
        return dict
    }

    // MARK: - Schema migration

    private func migrateThemeDict(_ raw: [String: Any]) -> [String: Any] {
        var dict = raw
        let version = dict["schemaVersion"] as? Int ?? 0

        if version < 1 {
            dict["schemaVersion"] = 1
        }
        // Future migrations: if version < 2 { ... }

        return dict
    }

    // MARK: - Variant support

    private func resolveVariantFromPrefs(themeName: String) -> String? {
        Preferences.load().snapshot.themeVariant[themeName]
    }

    private func resolveAndApplyVariant(raw: [String: Any], variantId: String) -> [String: Any] {
        guard let variants = raw["variants"] as? [String: Any],
              let spec = variants[variantId] as? [String: Any] else {
            logger.info("Variant '\(variantId, privacy: .public)' not found in theme")
            return raw
        }

        // Filter to allowed keys only
        let filtered = spec.filter { VARIANT_ALLOWED_KEYS.contains($0.key) }
        guard !filtered.isEmpty else { return raw }

        return deepMerge(base: raw, patch: filtered)
    }

    /// Recursively merge `patch` into `base`.
    /// Fields in VARIANT_REPLACE_FIELDS are replaced wholesale.
    /// Dicts are merged recursively. All other values are overwritten.
    private func deepMerge(base: [String: Any], patch: [String: Any]) -> [String: Any] {
        var result = base
        for (key, patchValue) in patch {
            if VARIANT_REPLACE_FIELDS.contains(key) {
                result[key] = patchValue
            } else if let baseDict = result[key] as? [String: Any],
                      let patchDict = patchValue as? [String: Any] {
                result[key] = deepMerge(base: baseDict, patch: patchDict)
            } else {
                result[key] = patchValue
            }
        }
        return result
    }

    // MARK: - SVG sanitization

    /// Returns a sanitized SVG path for user themes, or the original path for bundled themes.
    private func sanitizedSVGPath(original: String, themeName: String) -> String {
        guard isUserThemePath(original) else { return original }

        // Only sanitize SVG files; return APNG/PNG files as-is
        let ext = (original as NSString).pathExtension.lowercased()
        guard ext == "svg" else { return original }

        let fileName = (original as NSString).lastPathComponent
        let cacheDir = themeCacheDirectory(for: themeName)
        let cachedPath = cacheDir + "/\(fileName)"

        let fm = FileManager.default
        if fm.fileExists(atPath: cachedPath),
           let origAttrs = try? fm.attributesOfItem(atPath: original),
           let cacheAttrs = try? fm.attributesOfItem(atPath: cachedPath),
           let origDate = origAttrs[.modificationDate] as? Date,
           let cacheDate = cacheAttrs[.modificationDate] as? Date,
           cacheDate >= origDate {
            return cachedPath
        }

        guard let content = try? String(contentsOfFile: original, encoding: .utf8) else {
            logger.error("Failed to read SVG for sanitization: \(original, privacy: .public)")
            return original
        }

        let sanitized = SVGSanitizer.sanitize(content)

        do {
            try fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
            try sanitized.write(toFile: cachedPath, atomically: true, encoding: .utf8)
            return cachedPath
        } catch {
            logger.error("Failed to write sanitized SVG: \(error, privacy: .public)")
            return original
        }
    }

    private func isUserThemePath(_ path: String) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath
        let themesDir = (getUserThemesPath() as NSString).resolvingSymlinksInPath
        return resolved.hasPrefix(themesDir)
    }

    private func themeCacheDirectory(for themeName: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.clawd/theme-cache/\(themeName)"
    }

    // MARK: - Cache helpers

    private func themeCacheKey(name: String, variant: String?) -> String {
        if let v = variant { return "\(name):\(v)" }
        return name
    }

    private func getUserThemesPath() -> String {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("clawd-on-mac/themes").path
    }

    /// Clear cache for a specific theme and all its variants (used for hot-reload).
    func clearCache(for name: String) {
        let keysToRemove = themes.keys.filter { $0 == name || $0.hasPrefix("\(name):") }
        for key in keysToRemove {
            themes.removeValue(forKey: key)
        }
        // Also clear sanitized SVG cache
        let cacheDir = themeCacheDirectory(for: name)
        try? FileManager.default.removeItem(atPath: cacheDir)
    }

    // MARK: - SVG path resolution

    func getSVGPath(for state: String, themeName: String) -> String? {
        guard let theme = loadTheme(named: themeName) else {
            return nil
        }

        guard let svgFiles = theme.states[state],
              let svgFile = svgFiles.first else {
            return nil
        }

        guard let resourcePath = Bundle.main.resourcePath else { return nil }

        // Search order: assets/svg/ (classic themes), then assets/ (APNG/mixed themes)
        let searchDirs = ["assets/svg", "assets"]
        for dir in searchDirs {
            let bundledPath = resourcePath + "/themes/\(themeName)/\(dir)/\(svgFile)"
            let userPath = getUserThemesPath() + "/\(themeName)/\(dir)/\(svgFile)"

            if FileManager.default.fileExists(atPath: bundledPath) {
                return bundledPath
            } else if FileManager.default.fileExists(atPath: userPath) {
                return sanitizedSVGPath(original: userPath, themeName: themeName)
            }
        }

        return nil
    }

    func getReactionSVG(for reaction: String, themeName: String) -> String? {
        guard let theme = loadTheme(named: themeName) else {
            return nil
        }

        switch reaction {
        case "drag": return theme.reactions?.drag?.file
        case "clickLeft": return theme.reactions?.clickLeft?.file
        case "clickRight": return theme.reactions?.clickRight?.file
        case "annoyed": return theme.reactions?.annoyed?.file
        case "double": return theme.reactions?.double?.files?.randomElement()
        default: return nil
        }
    }

    func getMiniStateSVG(for state: String, themeName: String) -> String? {
        guard let theme = loadTheme(named: themeName) else {
            return nil
        }

        guard let miniStates = theme.miniMode?.states,
              let svgFiles = miniStates[state],
              let svgFile = svgFiles.first else {
            return nil
        }

        guard let resourcePath = Bundle.main.resourcePath else { return nil }

        let searchDirs = ["assets/svg", "assets"]
        for dir in searchDirs {
            let bundledPath = resourcePath + "/themes/\(themeName)/\(dir)/\(svgFile)"
            let userPath = getUserThemesPath() + "/\(themeName)/\(dir)/\(svgFile)"

            if FileManager.default.fileExists(atPath: bundledPath) {
                return bundledPath
            } else if FileManager.default.fileExists(atPath: userPath) {
                return sanitizedSVGPath(original: userPath, themeName: themeName)
            }
        }

        return nil
    }

    /// Returns the directory name used for this theme on disk.
    func directoryName(for theme: Theme) -> String? {
        guard let key = themes.first(where: { $0.value.name == theme.name })?.key else {
            return nil
        }
        // Strip variant suffix from cache key (e.g. "clawd:dark" → "clawd")
        if let colonIdx = key.firstIndex(of: ":") {
            return String(key[key.startIndex..<colonIdx])
        }
        return key
    }

    func validateTheme(_ theme: Theme) -> [String] {
        var errors: [String] = []

        let requiredStates = ["idle", "working", "thinking"]
        for state in requiredStates {
            if theme.states[state] == nil {
                errors.append("Missing required state: \(state)")
            }
        }

        if theme.eyeTracking?.enabled == true {
            let eyeStates = theme.eyeTracking?.states ?? []
            for state in eyeStates {
                if theme.states[state] == nil {
                    errors.append("Eye tracking enabled for unknown state: \(state)")
                }
            }
        }

        if let miniModeConfig = theme.miniMode, miniModeConfig.supported == true {
            let miniStates = ["mini-idle", "mini-enter", "mini-peek", "mini-alert", "mini-happy", "mini-crabwalk", "mini-enter-sleep", "mini-sleep"]
            let definedStates = miniModeConfig.states ?? [:]
            for state in miniStates {
                if definedStates[state] == nil {
                    errors.append("Mini mode declared but missing state: \(state)")
                }
            }
        }

        return errors
    }
}

extension Theme {

    static func placeholder() -> Theme {
        return Theme(
            schemaVersion: 1,
            name: "placeholder",
            author: nil,
            version: nil,
            description: nil,
            viewBox: nil,
            layout: nil,
            eyeTracking: nil,
            states: [
                "idle": ["placeholder.svg"]
            ],
            workingTiers: nil,
            jugglingTiers: nil,
            idleAnimations: nil,
            displayHintMap: nil,
            timings: nil,
            hitBoxes: nil,
            wideHitboxFiles: nil,
            sleepingHitboxFiles: nil,
            reactions: nil,
            miniMode: nil,
            sounds: nil,
            objectScale: nil,
            transitions: nil
        )
    }
}