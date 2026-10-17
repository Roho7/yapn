import Foundation

public enum SkillCatalog {
    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/skills")

    /// Names of the directories that hold a SKILL.md, sorted, each listed once.
    /// A missing or unreadable directory contributes nothing.
    public static func load(from directories: [URL] = [defaultDirectory]) -> [String] {
        let fileManager = FileManager.default
        let names = directories.flatMap { directory in
            ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }
                .map(\.lastPathComponent)
        }
        return Array(Set(names)).sorted()
    }

    /// Commands and bundled skills that ship with Claude Code itself, so they never appear in a skills directory.
    public static let claudeCodeSlashCommands: [String] = [
        "add-dir", "agents", "clear", "compact", "config", "context", "cost", "doctor", "exit", "export",
        "help", "hooks", "ide", "init", "login", "logout", "loop", "mcp", "memory", "model", "permissions",
        "plugin", "pr-comments", "release-notes", "resume", "review", "rewind", "schedule", "security-review",
        "simplify", "status", "statusline", "terminal-setup", "upgrade", "vim",
    ]
}
