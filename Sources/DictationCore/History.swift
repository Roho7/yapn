import Foundation

/// One completed dictation as the app saw it, kept so it can be labelled into the real-voice eval set.
public struct HistoryEntry: Codable, Sendable, Equatable {
    public let recordedAt: Date
    public let raw: String
    public let formatted: String
    /// Nil when LLM cleanup was off.
    public let cleanup: HistoryCleanup?
    public let pasted: String
    /// The app frontmost at hotkey-down, where the text was pasted.
    public let frontmostApp: String?
    /// Nil in entries written before styles existed, and when the app gave no title.
    public let windowTitle: String?
    /// Nil in entries written before styles existed, which were all written as `default`.
    public let style: DictationStyle?
    public let timings: HistoryTimings

    public init(recordedAt: Date, raw: String, formatted: String, cleanup: HistoryCleanup?, pasted: String, frontmostApp: String?, windowTitle: String? = nil, style: DictationStyle? = nil, timings: HistoryTimings) {
        self.recordedAt = recordedAt
        self.raw = raw
        self.formatted = formatted
        self.cleanup = cleanup
        self.pasted = pasted
        self.frontmostApp = frontmostApp
        self.windowTitle = windowTitle
        self.style = style
        self.timings = timings
    }
}

public enum HistoryCleanup: Codable, Sendable, Equatable {
    case skipped
    case cleaned(text: String)
    /// `llmOutput` is nil when the cleaner threw.
    case fellBack(reason: String, llmOutput: String?)

    public init(_ outcome: CleanupOutcome) {
        switch outcome {
        case .skipped: self = .skipped
        case .accepted(let text): self = .cleaned(text: text)
        case .rejected(let output, let rejection): self = .fellBack(reason: "\(rejection)", llmOutput: output)
        }
    }
}

public struct HistoryTimings: Codable, Sendable, Equatable {
    public let audioSeconds: Double
    public let stopMs: Double
    public let transcribeMs: Double
    public let formatMs: Double
    /// Nil when LLM cleanup was off.
    public let cleanupMs: Double?
    public let releaseToPasteMs: Double
    /// Nil when nothing read the pasted text, so the paste did not land.
    public let firstPasteboardReadMs: Double?

    public init(audioSeconds: Double, stopMs: Double, transcribeMs: Double, formatMs: Double, cleanupMs: Double?, releaseToPasteMs: Double, firstPasteboardReadMs: Double?) {
        self.audioSeconds = audioSeconds
        self.stopMs = stopMs
        self.transcribeMs = transcribeMs
        self.formatMs = formatMs
        self.cleanupMs = cleanupMs
        self.releaseToPasteMs = releaseToPasteMs
        self.firstPasteboardReadMs = firstPasteboardReadMs
    }
}

/// Written next to an entry once `bench label` has turned it into a clip, so labelling resumes where it stopped.
public struct HistoryLabel: Codable, Sendable, Equatable {
    public let clipsDirectory: String
    public let clipID: Int

    public init(clipsDirectory: String, clipID: Int) {
        self.clipsDirectory = clipsDirectory
        self.clipID = clipID
    }
}

public struct HistoryItem: Sendable {
    public let directory: URL
    public let entry: HistoryEntry
    public let label: HistoryLabel?

    public var audioURL: URL { directory.appendingPathComponent("audio.wav") }
}

/// `<directory>/<yyyyMMdd-HHmmss-SSS>/` per dictation: `audio.wav` holds the exact 16 kHz samples Parakeet
/// transcribed, `entry.json` the text at every stage. The JSON is written last, so an entry exists only once
/// both files are complete. Nothing here leaves the Mac.
public struct HistoryStore: Sendable {
    public let directory: URL

    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Yapn/history")

    public init(directory: URL) {
        self.directory = directory
    }

    @discardableResult
    public func save(_ entry: HistoryEntry, samples: [Float]) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let entryDirectory = directory.appendingPathComponent(formatter.string(from: entry.recordedAt))
        try FileManager.default.createDirectory(at: entryDirectory, withIntermediateDirectories: true)
        try writeWAV(samples, to: entryDirectory.appendingPathComponent("audio.wav"))
        try write(entry, to: entryDirectory.appendingPathComponent("entry.json"))
        return entryDirectory
    }

    /// Complete entries, oldest first.
    public func items() throws -> [HistoryItem] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .compactMap { entryDirectory -> HistoryItem? in
                let json = entryDirectory.appendingPathComponent("entry.json")
                guard FileManager.default.fileExists(atPath: json.path),
                      FileManager.default.fileExists(atPath: entryDirectory.appendingPathComponent("audio.wav").path)
                else { return nil }
                let label = entryDirectory.appendingPathComponent("label.json")
                return HistoryItem(
                    directory: entryDirectory,
                    entry: try decoder.decode(HistoryEntry.self, from: Data(contentsOf: json)),
                    label: FileManager.default.fileExists(atPath: label.path)
                        ? try decoder.decode(HistoryLabel.self, from: Data(contentsOf: label))
                        : nil
                )
            }
            .sorted { $0.entry.recordedAt < $1.entry.recordedAt }
    }

    public func markLabelled(_ item: HistoryItem, _ label: HistoryLabel) throws {
        try write(label, to: item.directory.appendingPathComponent("label.json"))
    }

    public func delete(_ item: HistoryItem) throws {
        try FileManager.default.removeItem(at: item.directory)
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

/// Turns a history entry into the next clip in `clips`, with `reference` as what should have been typed.
/// Backticked spans in the reference become the clip's dev tokens. The clip is saved before the entry is
/// marked, so a crash in between leaves a duplicate clip rather than a lost one.
@discardableResult
public func labelClip(_ item: HistoryItem, reference: String, into clips: ClipStore, history: HistoryStore) throws -> Prompt {
    let (written, tokens) = try splitBackticks(reference)
    let prompt = Prompt(id: (try clips.clips().map(\.prompt.id).max() ?? 0) + 1, category: .dictation, written: written, tokens: tokens)
    try clips.save(prompt, samples: try loadSamples(from: item.audioURL))
    try history.markLabelled(item, HistoryLabel(clipsDirectory: clips.directory.path, clipID: prompt.id))
    return prompt
}
