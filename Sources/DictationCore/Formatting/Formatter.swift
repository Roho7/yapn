/// The names the resolver may write. It never writes anything that is not in here.
public struct FormattingContext: Sendable, Equatable {
    public var skills: [String]
    public var slashCommands: [String]
    public var flags: [String]

    public init(skills: [String] = [], slashCommands: [String] = [], flags: [String] = []) {
        self.skills = skills
        self.slashCommands = slashCommands
        self.flags = flags
    }

    /// Every string the resolver can produce, written as it would appear: `/grill-me`, `--dry-run`.
    public var vocabulary: [String] {
        spokenSymbols.flatMap { rule in (rule.names?(self) ?? []).map { rule.symbol + $0 } }
    }
}

/// Turns a raw transcript into what a developer meant. Four stages run in order:
/// hesitations ("uh", "um") and stutters ("the the") are dropped,
/// spoken symbols ("slash", "dot", "dash dash", "underscore") are recognised from `spokenSymbols`,
/// a symbol that introduces a name ("/" or "--") is resolved against `context`,
/// then spoken breaks and list markers (`spokenBreaks`, `listMarkers`) lay the text out as lines and Markdown lists.
/// Text where no rule fires comes back unchanged, apart from whitespace runs collapsing to one space.
public func format(_ raw: String, context: FormattingContext) -> String {
    layout(resolveNames(recognizeSymbols(removeDisfluencies(lex(raw))), context: context))
}

struct Word: Equatable {
    let text: String
    /// Sentence punctuation the engine attached, kept apart so "review." still resolves.
    let trailing: String
}

enum Element {
    case word(Word)
    case symbol(SpokenSymbol, spoken: [Word])
    case name(String, trailing: String)

    var isWord: Bool {
        if case .word = self { true } else { false }
    }

    var isBareWord: Bool {
        if case .word(let word) = self { word.trailing.isEmpty } else { false }
    }

    var isSingleLetter: Bool {
        if case .word(let word) = self { word.text.count == 1 && word.text.first?.isLetter == true } else { false }
    }
}

let sentencePunctuation: Set<Character> = [",", ".", "?", "!", ";", ":"]

/// The engine sometimes writes a slash and the word for it ("src/slash lib"). Only the spoken word is kept,
/// so the rules decide the spacing instead of the engine.
func lex(_ raw: String) -> [Word] {
    raw.replacing(#/\/((?:forward\s+)?slash)\b/#.ignoresCase(), with: { " " + $0.1 })
        .split(whereSeparator: \.isWhitespace)
        .map { token in
            var text = String(token)
            var trailing = ""
            while text.count > 1, let last = text.last, sentencePunctuation.contains(last) {
                trailing.insert(text.removeLast(), at: trailing.startIndex)
            }
            return Word(text: text, trailing: trailing)
        }
}

private let phraseTable: [(phrase: [String], rule: SpokenSymbol)] = spokenSymbols
    .flatMap { rule in rule.phrases.map { (phrase: $0, rule: rule) } }
    .sorted { $0.phrase.count > $1.phrase.count }

func recognizeSymbols(_ words: [Word]) -> [Element] {
    var elements: [Element] = []
    var i = 0
    while i < words.count {
        let match = phraseTable.first { entry in
            let end = i + entry.phrase.count
            guard end <= words.count else { return false }
            return zip(entry.phrase, words[i..<end]).allSatisfy { $0 == $1.text.lowercased() && $1.trailing.isEmpty }
        }
        if let match {
            let end = i + match.phrase.count
            elements.append(.symbol(match.rule, spoken: Array(words[i..<end])))
            i = end
        } else {
            elements.append(.word(words[i]))
            i += 1
        }
    }
    return elements
}

/// A name may span up to this many spoken words ("slash grill with docs").
let maxNameWords = 4

func resolveNames(_ elements: [Element], context: FormattingContext) -> [Element] {
    var resolved: [Element] = []
    var i = 0
    while i < elements.count {
        if case .symbol(let rule, _) = elements[i],
           let names = rule.names,
           !continuesChain(resolved),
           let hit = resolveName(after: i, in: elements, resolver: NameResolver(names: names(context))) {
            resolved.append(.name(rule.symbol + hit.name, trailing: hit.trailing))
            i += 1 + hit.wordCount
        } else {
            resolved.append(elements[i])
            i += 1
        }
    }
    return resolved
}

/// "src slash lib slash review": the second slash sits inside a path, so it never starts a command.
private func continuesChain(_ before: [Element]) -> Bool {
    guard before.count >= 2, before[before.count - 1].isWord else { return false }
    if case .symbol = before[before.count - 2] { return true }
    return false
}

private func resolveName(after symbolIndex: Int, in elements: [Element], resolver: NameResolver) -> (name: String, wordCount: Int, trailing: String)? {
    var words: [Word] = []
    for element in elements[(symbolIndex + 1)...].prefix(maxNameWords) {
        guard case .word(let word) = element else { break }
        words.append(word)
        if !word.trailing.isEmpty { break }
    }
    guard let hit = resolver.match(words) else { return nil }
    let after = symbolIndex + 1 + hit.wordCount
    if after < elements.count, case .symbol = elements[after] { return nil }
    return (hit.name, hit.wordCount, words[hit.wordCount - 1].trailing)
}

/// Space between neighbours unless either side glues.
func render(_ elements: [Element]) -> String {
    var result = ""
    var gluesRight = false
    for (i, element) in elements.enumerated() {
        let text: String
        let glue: Glue
        switch element {
        case .word(let word):
            (text, glue) = (word.text + word.trailing, Glue(left: false, right: false))
        case .name(let name, let trailing):
            (text, glue) = (name + trailing, Glue(left: false, right: false))
        case .symbol(let rule, let spoken):
            if let symbolGlue = rule.glue(neighbours(of: i, in: elements)) {
                (text, glue) = (rule.symbol, symbolGlue)
            } else {
                (text, glue) = (spoken.map { $0.text + $0.trailing }.joined(separator: " "), Glue(left: false, right: false))
            }
        }
        if !result.isEmpty, !gluesRight, !glue.left { result += " " }
        result += text
        gluesRight = glue.right
    }
    return result
}

func neighbours(of index: Int, in elements: [Element]) -> Neighbours {
    var continuesFlag = false
    if index >= 2, elements[index - 1].isBareWord, case .symbol(let rule, _) = elements[index - 2] {
        continuesFlag = rule.symbol.hasPrefix("-")
    }
    return Neighbours(
        previous: index > 0 ? elements[index - 1] : nil,
        next: index + 1 < elements.count ? elements[index + 1] : nil,
        continuesFlag: continuesFlag
    )
}
