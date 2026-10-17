import ArgumentParser
import DictationCore
import Foundation

struct Label: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Turn the app's dictation history into clips: write what each dictation should have typed."
    )

    @Option(help: "History directory the app writes with keepHistory on.") var history = HistoryStore.defaultDirectory.path
    @Option(help: "Clip directory the labelled dictations are added to.") var out = "data/real-clips"

    func run() throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let historyStore = HistoryStore(directory: URL(fileURLWithPath: (history as NSString).expandingTildeInPath))
        let clips = ClipStore(directory: URL(fileURLWithPath: out))
        let items = try historyStore.items()
        let pending = items.filter { $0.label == nil }
        print("\(items.count - pending.count)/\(items.count) history entries labelled in \(historyStore.directory.path)")

        for (index, item) in pending.enumerated() {
            let entry = item.entry
            print("\n[\(index + 1)/\(pending.count)] \(item.directory.lastPathComponent)\(entry.frontmostApp.map { " in \($0)" } ?? "")")
            print("raw:       \(indented(entry.raw))")
            if let cleanup = entry.cleanup { print("cleanup:   \(describe(cleanup))") }
            print("pasted:    \(indented(entry.pasted))")
            switch try LabelFlow(item: item).run() {
            case .labelled(let reference):
                let prompt = try labelClip(item, reference: reference, into: clips, history: historyStore)
                print("saved \(String(format: "%03d", prompt.id)).wav in \(clips.directory.path)")
            case .skipped:
                continue
            case .deleted:
                try historyStore.delete(item)
                print("deleted \(item.directory.lastPathComponent)")
            case .quit:
                return
            }
        }
        print("\nnothing left to label; clips are in \(clips.directory.path)")
    }
}

enum LabelOutcome {
    case labelled(reference: String)
    case skipped
    case deleted
    case quit
}

/// One history entry from shown to labelled. The reference starts as the pasted text and can be rewritten
/// in $EDITOR, from the pasted text or from the raw transcript, as often as needed before it is accepted.
struct LabelFlow {
    private enum Phase {
        case choosing(reference: String)
        case confirmingDelete(reference: String)
        case done(LabelOutcome)
    }

    let item: HistoryItem

    func run() throws -> LabelOutcome {
        var phase = Phase.choosing(reference: item.entry.pasted)
        while true {
            switch phase {
            case .choosing(let reference):
                print("reference: \(indented(reference))")
                print("Enter accept, t type the correct text, e edit in $EDITOR, r edit from raw, p play, s skip, d delete, q quit")
                switch readInput() {
                case "" where reference.isEmpty:
                    print("the reference is empty; e to write one, s to skip")
                case "":
                    do {
                        _ = try splitBackticks(reference)
                        phase = .done(.labelled(reference: reference))
                    } catch {
                        print("\(error); e to fix it")
                    }
                case "t":
                    print("type the correct text, then Enter (empty keeps the current one):")
                    let typed = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
                    phase = .choosing(reference: typed.isEmpty ? reference : typed)
                case "e": phase = .choosing(reference: try edit(reference) ?? reference)
                case "r": phase = .choosing(reference: try edit(item.entry.raw) ?? reference)
                case "p": try afplay(item.audioURL)
                case "s": phase = .done(.skipped)
                case "d": phase = .confirmingDelete(reference: reference)
                case "q", nil: phase = .done(.quit)
                default: break
                }
            case .confirmingDelete(let reference):
                print("delete this entry's audio and text for good? y to delete, anything else to go back")
                phase = readInput() == "y" ? .done(.deleted) : .choosing(reference: reference)
            case .done(let outcome):
                return outcome
            }
        }
    }

    /// The saved file's text, or nil when the editor failed or the file came back empty.
    private func edit(_ text: String) throws -> String? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bench-label-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try (text + "\n").write(to: file, atomically: true, encoding: .utf8)
        let editor = ProcessInfo.processInfo.environment["EDITOR"].flatMap { $0.isEmpty ? nil : $0 } ?? "nano"
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Through the shell so an EDITOR with arguments, like "code -w", works.
        shell.arguments = ["-c", "\(editor) \"$0\"", file.path]
        try shell.run()
        shell.waitUntilExit()
        guard shell.terminationStatus == 0 else {
            print("\(editor) exited with \(shell.terminationStatus); reference unchanged")
            return nil
        }
        let edited = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        if edited.isEmpty { print("the file came back empty; reference unchanged") }
        return edited.isEmpty ? nil : edited
    }

    private func readInput() -> String? {
        readLine().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }
}

private func describe(_ cleanup: HistoryCleanup) -> String {
    switch cleanup {
    case .skipped: "skipped (no correction cue or list)"
    case .cleaned(let text): "cleaned to \(indented(text))"
    case .fellBack(let reason, _): "fell back (\(reason))"
    }
}

/// Multi-line text with its continuation lines lined up under the first.
private func indented(_ text: String) -> String {
    text.isEmpty ? "<empty>" : text.replacingOccurrences(of: "\n", with: "\n           ")
}
