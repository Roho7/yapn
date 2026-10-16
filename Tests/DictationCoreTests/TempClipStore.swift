import DictationCore
import Foundation

func withTempClipStore<T>(_ body: (ClipStore) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipstore-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(ClipStore(directory: directory))
}
