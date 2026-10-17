import DictationCore
import Foundation

/// Builds a skills directory with one subdirectory per entry; `true` gives it a SKILL.md.
func withTempSkillsDirectory<T>(_ entries: [String: Bool], _ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    for (name, hasSkillFile) in entries {
        let skill = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        if hasSkillFile {
            try Data("# \(name)\n".utf8).write(to: skill.appendingPathComponent("SKILL.md"))
        }
    }
    return try body(directory)
}

func missingDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("no-such-skills-\(UUID().uuidString)")
}
