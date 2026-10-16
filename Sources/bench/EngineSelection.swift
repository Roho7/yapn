import ArgumentParser
import DictationCore
import Foundation

func parseEngines(_ spec: String) throws -> [EngineVariant] {
    if spec == "all" { return EngineVariant.all }
    return try spec.split(separator: ",").map { id in
        guard let variant = EngineVariant(id: String(id)) else {
            throw ValidationError("unknown engine '\(id)'; valid: \(EngineVariant.all.map(\.id).joined(separator: ", "))")
        }
        return variant
    }
}

func loadVocab(path: String) throws -> [String] {
    try String(contentsOfFile: path, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}
