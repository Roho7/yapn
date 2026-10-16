import Foundation

public struct Clip: Sendable {
    public let prompt: Prompt
    public let audioURL: URL

    public init(prompt: Prompt, audioURL: URL) {
        self.prompt = prompt
        self.audioURL = audioURL
    }
}

/// A directory of `NNN.wav` + `NNN.json` pairs, NNN being the zero-padded prompt id.
/// The JSON is written last, so a clip exists only once both files are complete.
public struct ClipStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func clips() throws -> [Clip] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder()
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { json -> Clip? in
                let wav = json.deletingPathExtension().appendingPathExtension("wav")
                guard FileManager.default.fileExists(atPath: wav.path) else { return nil }
                return Clip(prompt: try decoder.decode(Prompt.self, from: Data(contentsOf: json)), audioURL: wav)
            }
            .sorted { $0.prompt.id < $1.prompt.id }
    }

    public func save(_ prompt: Prompt, samples: [Float]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = String(format: "%03d", prompt.id)
        try writeWAV(samples, to: directory.appendingPathComponent("\(stem).wav"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(prompt).write(to: directory.appendingPathComponent("\(stem).json"), options: .atomic)
    }
}
