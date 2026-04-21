import Foundation
import AppKit
import os

/// Lightweight update checker for ClawdOnMac.
/// Checks a GitHub releases endpoint for newer versions.
/// Can be upgraded to Sparkle framework for full auto-update later.
private let logger = Logger(subsystem: "com.clawd.onmac", category: "UpdateChecker")

class UpdateChecker {

    static let shared = UpdateChecker()

    /// GitHub owner/repo for release checking.
    private let owner = "anthropics"
    private let repo = "clawd"

    /// Current app version from Info.plist.
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Last check timestamp.
    private var lastCheckDate: Date?

    /// Minimum interval between checks (1 hour).
    private let checkInterval: TimeInterval = 3600

    /// Latest known release info.
    private(set) var latestRelease: ReleaseInfo?

    /// Whether an update is available.
    var updateAvailable: Bool {
        guard let latest = latestRelease else { return false }
        return compareVersions(latest.version, isNewerThan: currentVersion)
    }

    struct ReleaseInfo {
        let version: String
        let downloadURL: URL?
        let releaseNotes: String
        let publishedAt: Date?
    }

    /// Check for updates. Must be called from main thread. Calls completion on main thread.
    func checkForUpdates(force: Bool = false, completion: ((ReleaseInfo?) -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        // Rate-limit non-forced checks
        if !force, let last = lastCheckDate, Date().timeIntervalSince(last) < checkInterval {
            DispatchQueue.main.async { completion?(self.latestRelease) }
            return
        }

        let urlString = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion?(nil) }
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self, let data, error == nil else {
                logger.error("Check failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
                DispatchQueue.main.async { completion?(nil) }
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                DispatchQueue.main.async { completion?(nil) }
                return
            }

            let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let body = json["body"] as? String ?? ""

            var downloadURL: URL?
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String,
                       name.hasSuffix(".dmg") || name.hasSuffix(".zip"),
                       let urlStr = asset["browser_download_url"] as? String {
                        downloadURL = URL(string: urlStr)
                        break
                    }
                }
            }

            var publishedAt: Date?
            if let dateStr = json["published_at"] as? String {
                let formatter = ISO8601DateFormatter()
                publishedAt = formatter.date(from: dateStr)
            }

            let release = ReleaseInfo(
                version: version,
                downloadURL: downloadURL,
                releaseNotes: body,
                publishedAt: publishedAt
            )

            let isNewer = self.compareVersions(version, isNewerThan: self.currentVersion)

            DispatchQueue.main.async {
                self.lastCheckDate = Date()
                self.latestRelease = release

                if isNewer {
                    logger.info("Update available: \(version, privacy: .public) (current: \(self.currentVersion, privacy: .public))")
                }

                completion?(release)
            }
        }.resume()
    }

    /// Open download page in browser.
    func openDownloadPage() {
        if let url = latestRelease?.downloadURL {
            NSWorkspace.shared.open(url)
        } else {
            let fallback = URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
            NSWorkspace.shared.open(fallback)
        }
    }

    // MARK: - Version comparison

    /// Simple semver comparison: returns true if `a` > `b`.
    /// Strips pre-release suffixes (e.g., "1.2.3-beta" → "1.2.3") before comparison.
    private func compareVersions(_ a: String, isNewerThan b: String) -> Bool {
        func parseVersion(_ v: String) -> [Int] {
            v.split(separator: ".").compactMap { part in
                // Strip pre-release suffix: "3-beta" → "3"
                let numeric = part.prefix(while: { $0.isNumber })
                return Int(numeric)
            }
        }
        let partsA = parseVersion(a)
        let partsB = parseVersion(b)

        let maxLen = max(partsA.count, partsB.count)
        for i in 0..<maxLen {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va > vb { return true }
            if va < vb { return false }
        }
        return false
    }
}
