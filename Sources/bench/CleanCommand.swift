import ArgumentParser
import DictationCore
import Foundation

struct Clean: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Pass raw transcripts, one per line on stdin, through the formatter and the on-device LLM cleanup, and print each verdict."
    )

    @Flag(help: "Send every line to the cleaner, not only those the gate lets through.") var all = false
    @Option(help: "Seconds between prewarming the cleaner and each cleanup call.") var pause = 1.0
    @Option(help: "Skills directory the formatter resolves names from.") var skillsDir = SkillCatalog.defaultDirectory.path

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let skillsURL = URL(fileURLWithPath: (skillsDir as NSString).expandingTildeInPath)
        let context = FormattingContext(skills: SkillCatalog.load(from: [skillsURL]), slashCommands: SkillCatalog.claudeCodeSlashCommands)
        guard case .ready(let cleaner) = makeSystemCleaner() else { throw ValidationError("cleanup unavailable on this Mac") }

        func oneLine(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\n", with: "\\n") + "\"" }
        var index = 0
        while let line = readLine() {
            guard !line.allSatisfy(\.isWhitespace) else { continue }
            index += 1
            let formatted = format(line, context: context)
            await cleaner.prewarm()
            if pause > 0 { try await Task.sleep(for: .seconds(pause)) }
            let result = await cleanup(formatted, with: cleaner, always: all)
            let head = String(format: "%3d %5.0f ms ", index, result.seconds * 1000)
            switch result.outcome {
            case .skipped:
                print("\(head)skipped   \(oneLine(formatted))")
            case .accepted(let output) where output == formatted:
                print("\(head)unchanged \(oneLine(formatted))")
            case .accepted(let output):
                print("\(head)cleaned\n      in:  \(oneLine(formatted))\n      out: \(oneLine(output))")
            case .rejected(let output, let rejection):
                print("\(head)fallback (\(rejection))\n      in:  \(oneLine(formatted))")
                if let output { print("      llm: \(oneLine(output))") }
            }
        }
    }
}
