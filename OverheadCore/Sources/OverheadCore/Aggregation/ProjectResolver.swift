import Foundation

/// Maps a session's working directory to the project it belongs to: the enclosing git
/// repository root, with git worktrees folded into their main repository. Directories
/// outside any repository stay as they are. The home directory is never treated as a root.
public struct ProjectResolver: Sendable {
    private let home: String

    public init(home: String? = nil) {
        self.home = home ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Resolve many paths, consulting the filesystem once per distinct directory.
    public func resolve(_ paths: [String?]) -> [String: String] {
        var out: [String: String] = [:]
        for case let p? in paths where out[p] == nil { out[p] = repoRoot(for: p) }
        return out
    }

    public func repoRoot(for path: String) -> String {
        let fileManager = FileManager.default
        var dir = path
        while dir != "/" && dir != home && !dir.isEmpty {
            let gitPath = dir + "/.git"
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: gitPath, isDirectory: &isDir) {
                if isDir.boolValue { return dir }
                // A worktree: ".git" is a file "gitdir: <main>/.git/worktrees/<name>".
                if let text = try? String(contentsOfFile: gitPath, encoding: .utf8),
                   let range = text.range(of: "gitdir:") {
                    let target = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if let marker = target.range(of: "/.git/worktrees/") {
                        return String(target[..<marker.lowerBound])
                    }
                }
                return dir
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return path
    }
}
