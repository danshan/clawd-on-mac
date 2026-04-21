import Foundation

/// Sync engine: creates symlinks or copies skill directories to tool-specific locations.
final class SyncEngine {

    enum SyncError: LocalizedError {
        case destinationInsideSource(src: String, dst: String)
        case syncFailed(String)

        var errorDescription: String? {
            switch self {
            case .destinationInsideSource(let src, let dst):
                return "Destination \(dst) is inside source \(src); refusing to copy to avoid infinite recursion"
            case .syncFailed(let msg):
                return "Sync failed: \(msg)"
            }
        }
    }

    /// Sync a skill directory to a target path using the specified mode.
    /// Returns the actual mode used (symlink may fall back to copy on non-Unix).
    @discardableResult
    func sync(source: URL, target: URL, mode: SyncMode) throws -> SyncMode {
        if let parent = target.deletingLastPathComponent() as URL? {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        // Remove existing target first
        removeTarget(at: target)

        switch mode {
        case .symlink:
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
            return .symlink
        case .copy:
            // Only check dst-inside-src for copy mode (symlinks don't recurse)
            try ensureDestinationNotInsideSource(src: source, dst: target)
            try copyDirectoryRecursive(src: source, dst: target)
            return .copy
        }
    }

    /// Remove a synced target (symlink, directory, or file).
    func removeTarget(at path: URL) {
        let fm = FileManager.default
        do {
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: path.path, isDirectory: &isDir)

            // Check symlink first
            if let _ = try? fm.destinationOfSymbolicLink(atPath: path.path) {
                try fm.removeItem(at: path)
                return
            }

            guard exists else { return }
            try fm.removeItem(at: path)
        } catch {
            // Best-effort removal
        }
    }

    // MARK: - Private

    private func ensureDestinationNotInsideSource(src: URL, dst: URL) throws {
        let srcResolved = src.resolvingSymlinksInPath()
        let dstResolved: URL
        if FileManager.default.fileExists(atPath: dst.path) {
            dstResolved = dst.resolvingSymlinksInPath()
        } else if let parent = dst.deletingLastPathComponent() as URL?,
                  FileManager.default.fileExists(atPath: parent.path) {
            dstResolved = parent.resolvingSymlinksInPath().appendingPathComponent(dst.lastPathComponent)
        } else {
            return
        }

        let srcPath = srcResolved.path.hasSuffix("/") ? srcResolved.path : srcResolved.path + "/"
        if dstResolved.path.hasPrefix(srcPath) {
            throw SyncError.destinationInsideSource(src: src.path, dst: dst.path)
        }
    }

    private func copyDirectoryRecursive(src: URL, dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)

        let contents = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        for item in contents {
            let name = item.lastPathComponent
            if name == ".git" { continue }
            let dest = dst.appendingPathComponent(name)

            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                try copyDirectoryRecursive(src: item, dst: dest)
            } else {
                try fm.copyItem(at: item, to: dest)
            }
        }
    }
}
