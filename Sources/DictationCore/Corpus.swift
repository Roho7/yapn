import Foundation

public enum PromptCategory: String, Codable, Sendable, CaseIterable {
    case claudePrompt = "claude-prompt"
    case skill
    case path
    case identifier
    case flag
    case prose
}

/// One test utterance. `written` is the reference text with backticks removed;
/// `tokens` are the backticked dev tokens in their exact written form.
public struct Prompt: Codable, Sendable, Hashable {
    public let id: Int
    public let category: PromptCategory
    public let written: String
    public let tokens: [String]

    public init(id: Int, category: PromptCategory, written: String, tokens: [String]) {
        self.id = id
        self.category = category
        self.written = written
        self.tokens = tokens
    }
}

public enum PromptFileError: Error, Equatable, CustomStringConvertible {
    case utteranceBeforeCategory(line: Int)
    case unknownCategory(String, line: Int)
    case unbalancedBackticks(line: Int)
    case emptyToken(line: Int)

    public var description: String {
        switch self {
        case .utteranceBeforeCategory(let line): "line \(line): utterance before any '# category:' header"
        case .unknownCategory(let raw, let line): "line \(line): unknown category '\(raw)'"
        case .unbalancedBackticks(let line): "line \(line): unbalanced backticks"
        case .emptyToken(let line): "line \(line): empty backtick pair"
        }
    }
}

public enum PromptFile {
    public static func parse(_ text: String) throws -> [Prompt] {
        var prompts: [Prompt] = []
        var category: PromptCategory?

        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                let body = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                guard body.hasPrefix("category:") else { continue }
                let raw = body.dropFirst("category:".count).trimmingCharacters(in: .whitespaces)
                guard let parsed = PromptCategory(rawValue: raw) else {
                    throw PromptFileError.unknownCategory(raw, line: lineNumber)
                }
                category = parsed
                continue
            }

            guard let category else { throw PromptFileError.utteranceBeforeCategory(line: lineNumber) }
            let segments = line.split(separator: "`", omittingEmptySubsequences: false).map(String.init)
            guard segments.count % 2 == 1 else { throw PromptFileError.unbalancedBackticks(line: lineNumber) }
            let tokens = segments.indices.filter { $0 % 2 == 1 }.map { segments[$0] }
            guard !tokens.contains(where: \.isEmpty) else { throw PromptFileError.emptyToken(line: lineNumber) }

            prompts.append(Prompt(
                id: prompts.count + 1,
                category: category,
                written: segments.joined(),
                tokens: tokens
            ))
        }
        return prompts
    }
}
