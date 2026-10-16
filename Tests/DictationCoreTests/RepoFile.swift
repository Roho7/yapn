import Foundation

// Kept apart from the Testing-importing files: the CLT toolchain ships no
// _Testing_Foundation overlay, so `import Foundation` + `import Testing` in one file fails to build.
func readRepoFile(_ relativePath: String, from file: String = #filePath) throws -> String {
    let repoRoot = URL(fileURLWithPath: file)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
}
