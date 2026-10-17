import DictationCore
import Foundation

func withTempHistory<T>(_ body: (HistoryStore, ClipStore) throws -> T) throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    return try body(HistoryStore(directory: root.appendingPathComponent("history")), ClipStore(directory: root.appendingPathComponent("clips")))
}

func historyEntry(atSecond second: Double, raw: String, pasted: String, cleanup: HistoryCleanup? = nil) -> HistoryEntry {
    HistoryEntry(
        recordedAt: Date(timeIntervalSince1970: 1_800_000_000 + second),
        raw: raw,
        formatted: pasted,
        cleanup: cleanup,
        pasted: pasted,
        frontmostApp: "com.apple.Terminal",
        timings: HistoryTimings(audioSeconds: 1, stopMs: 2, transcribeMs: 30, formatMs: 0.5, cleanupMs: nil, releaseToPasteMs: 40, firstPasteboardReadMs: 3)
    )
}

/// Leaves a directory with audio but no entry.json, as a crash mid-save would.
func writeTornEntry(in history: HistoryStore, samples: [Float]) throws {
    let directory = history.directory.appendingPathComponent("20270101-000000-000")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try writeWAV(samples, to: directory.appendingPathComponent("audio.wav"))
}

/// An entry.json as the app wrote it before styles existed.
func decodeLegacyEntry() throws -> HistoryEntry {
    let json = """
    {"cleanup":{"skipped":{}},"formatted":"git status","frontmostApp":"com.apple.Terminal","pasted":"git status","raw":"Git status.",
     "recordedAt":"2026-10-17T10:00:00Z","timings":{"audioSeconds":1,"formatMs":0.1,"releaseToPasteMs":40,"stopMs":2,"transcribeMs":30}}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(HistoryEntry.self, from: Data(json.utf8))
}
