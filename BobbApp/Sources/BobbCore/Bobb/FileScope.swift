import Foundation

public enum FileScope {
    /// Relative names only. Resolve symlinks and require a component boundary.
    public static func resolve(_ relative: String, root: URL) -> URL? {
        guard !relative.hasPrefix("/"), !relative.contains("\0"), relative.count <= 4096,
              !relative.split(separator: "/").contains("..") else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        var candidate = base
        for component in relative.split(separator: "/") where component != "." {
            candidate.appendPathComponent(String(component))
            // ResolveSymlinks may leave a missing leaf untouched. Inspect each
            // existing ancestor, including dangling links, before appending it.
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) != nil { return nil }
        }
        candidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path == base.path || candidate.path.hasPrefix(base.path + "/") else { return nil }
        return candidate
    }
}
