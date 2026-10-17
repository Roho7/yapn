/// Capitalises each sentence's first word and ends the text with a full stop when it ends in a word.
/// Code tokens and words already capitalised keep their case.
func formalSentences(_ text: String) -> String {
    var result = ""
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if !result.isEmpty { result += "\n" }
        var startsSentence = true
        var words: [String] = []
        for word in line.split(separator: " ", omittingEmptySubsequences: false) {
            let word = String(word)
            words.append(startsSentence ? capitalisedIfLowercase(word) : word)
            if !word.isEmpty { startsSentence = word.last.map { ".?!".contains($0) } ?? false }
        }
        result += words.joined(separator: " ")
    }
    if let last = result.last, last.isLetter || last.isNumber { result += "." }
    return result
}

/// "we're" is "We're"; "iPhone", "src/lib" and "--verbose" keep their case.
private func capitalisedIfLowercase(_ word: String) -> String {
    let head = String(word.prefix { !sentencePunctuation.contains($0) })
    guard let first = head.first, isPlainWord(head), head == head.lowercased() else { return word }
    return first.uppercased() + word.dropFirst()
}

/// Conjunctions a formal sentence does not open with: "And so", "But like", "So".
private let formalLeadingConjunctions: Set<String> = ["and", "but", "so", "plus"]

/// Crutches the formal rules delete without the model. "like" and "you know" are also comparisons and verbs
/// ("tools like Figma", "You know the drill."), so they go only at a pause: next to a comma or after a leading
/// conjunction ("But like the main lesson"). Each also keeps the `crutches` table's `notAfter`
/// words, so "what kind of tools" and "do you know" stay.
private let formalCrutchWords: [(words: [String], atPauseOnly: Bool)] = [
    (["basically"], false), (["honestly"], false), (["literally"], false),
    (["kind", "of"], false), (["sort", "of"], false),
    (["like"], true), (["you", "know"], true),
]

/// Deletes the crutches a formal text never keeps and the conjunctions stacked at a sentence's head.
/// A deleted crutch takes its comma with it, and the comma before it when it sat between two ("I'm, like, super").
/// A full stop on it moves to the word before. The model handles the rest under `reviewCleanup(formal:)`.
func withoutFormalCrutches(_ words: [Word]) -> [Word] {
    func key(_ word: Word) -> String { word.text.lowercased().filter { $0 != "'" && $0 != "\u{2019}" } }
    var kept: [Word] = []
    var atHead = true
    var droppedConjunction = false
    var i = 0
    while i < words.count {
        let previous = kept.last
        let afterConjunction = droppedConjunction || (previous.map { formalLeadingConjunctions.contains(key($0)) } ?? false)
        let length: Int? = {
            if atHead, formalLeadingConjunctions.contains(key(words[i])), i + 1 < words.count, !words[i].endsSentence { return 1 }
            return formalCrutchWords.first { entry in
                let end = i + entry.words.count
                guard end <= words.count, words[i..<end].map(key) == entry.words,
                      words[i..<(end - 1)].allSatisfy({ $0.trailing.isEmpty }), end < words.count || words[end - 1].endsSentence else { return false }
                let notAfter = crutches.first { $0.words == entry.words }?.notAfter ?? []
                if let previous, notAfter.contains(key(previous)) { return false }
                let atPause = afterConjunction || previous?.trailing == "," || words[end - 1].trailing == ","
                return !entry.atPauseOnly || atPause
            }?.words.count
        }()
        guard let length else {
            kept.append(words[i])
            atHead = words[i].endsSentence
            droppedConjunction = false
            i += 1
            continue
        }
        droppedConjunction = droppedConjunction || (atHead && formalLeadingConjunctions.contains(key(words[i])))
        let dropped = words[i + length - 1]
        if let previous, !previous.endsSentence {
            if dropped.endsSentence {
                kept[kept.count - 1] = Word(text: previous.text, trailing: dropped.trailing)
            } else if dropped.trailing == ",", previous.trailing == "," {
                kept[kept.count - 1] = Word(text: previous.text, trailing: "")
            }
        }
        i += length
    }
    return kept
}

/// Words that end a spoken flag name: "with the verbose flag" names `verbose`, not `with-the-verbose`.
private let flagNameStops: Set<String> = [
    "the", "a", "an", "with", "and", "then", "or", "to", "use", "using", "pass", "add", "set", "run",
    "flag", "short", "long", "argument", "arguments", "option",
]

/// Flags whose names span words. A spoken name not in here and not in the context's flags is one word long,
/// so "npm test verbose flag" is `npm test --verbose`, not `npm --test-verbose`.
let commonMultiWordFlags = [
    "dry-run", "no-verify", "force-with-lease", "save-dev", "save-exact", "set-upstream", "no-cache", "no-edit",
    "allow-empty", "no-ff", "ignore-case", "follow-tags", "name-only", "max-count", "no-install", "watch-all",
]

/// The rules for a shell prompt. The text is a command line, so it comes out as one line with no sentence
/// punctuation and no capital on a sentence's first word, and nothing here ever writes a newline: a pasted newline runs it.
/// Before the spoken symbols: "verbose flag" is `--verbose`, and so is "flag verbose" after a pause or with no name
/// before it; "dry run flag" is `--dry-run` when the name is a known flag; "short flag v" is `-v`, "long flag X" is `--X`,
/// and "argument X" or "pass X" is `X`. "with" and an article right before a flag go: "with the verbose flag" is "--verbose".
/// The engine's spellings are undone first: letters spoken one by one join ("C D S R C" is "cd src"), a lone letter is
/// lowercase unless "capital" comes first, a known program or subcommand loses its capitals ("NPM", "Compose"),
/// and "get" before a git subcommand is "git".
func shellCommand(_ raw: String, context: FormattingContext) -> String {
    let flags = NameResolver(names: context.flags + commonMultiWordFlags)
    let spoken = commandWordsWritten(lettersWritten(lowercasingSentenceStarts(removeDisfluencies(lex(raw)))))
    let words = droppingConnectivesBeforeFlags(shellPhrases(spoken, flags: flags)).map { Word(text: $0.text, trailing: "") }
    return render(resolveNames(recognizeSymbols(words), context: context))
}

private func shellPhrases(_ words: [Word], flags: NameResolver) -> [Word] {
    func text(_ index: Int) -> String? { words.indices.contains(index) ? words[index].text.lowercased() : nil }
    func flag(_ name: String) -> Word { Word(text: name, trailing: "") }
    var result: [Word] = []
    var i = 0
    while i < words.count {
        let current = text(i)
        let paused = result.last.map { !$0.trailing.isEmpty } ?? true
        if current == "short", text(i + 1) == "flag", let letter = text(i + 2), letter.count == 1, letter.first?.isLetter == true {
            result.append(flag("-" + letter))
            i += 3
        } else if current == "long", text(i + 1) == "flag", let hit = flagName(after: i + 1, in: words, flags: flags) {
            result.append(flag("--" + hit.name))
            i += 2 + hit.count
        } else if current == "flag", !paused, let hit = flagName(before: result, flags: flags) {
            result.removeLast(hit.count)
            result.append(flag("--" + hit.name))
            i += 1
        } else if current == "flag", let hit = flagName(after: i, in: words, flags: flags) {
            result.append(flag("--" + hit.name))
            i += 1 + hit.count
        } else if current == "argument" || current == "arguments" || (current == "pass" && !result.isEmpty), i + 1 < words.count {
            i += 1
        } else {
            result.append(words[i])
            i += 1
        }
    }
    return result
}

/// A word that can be part of a flag's name: "verbose", "dry-run", "utf8".
private func isFlagWord(_ word: Word) -> Bool {
    word.text.first?.isLetter == true && word.text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
}

/// The flag named right after `index`: a known multi-word flag, else the next word unless it is a stop word.
private func flagName(after index: Int, in words: [Word], flags: NameResolver) -> (name: String, count: Int)? {
    var name: [Word] = []
    for word in words.dropFirst(index + 1).prefix(maxNameWords) {
        guard isFlagWord(word) else { break }
        name.append(word)
        if !word.trailing.isEmpty { break }
    }
    if let hit = flags.match(name) { return (hit.name, hit.wordCount) }
    guard let first = name.first, !flagNameStops.contains(first.text.lowercased()) else { return nil }
    return (first.text.lowercased(), 1)
}

/// The flag named at the end of `words`: the longest known multi-word flag ending there, else the last word unless it is a stop word.
private func flagName(before words: [Word], flags: NameResolver) -> (name: String, count: Int)? {
    var name: [Word] = []
    for (offset, word) in words.reversed().prefix(maxNameWords).enumerated() {
        guard isFlagWord(word), offset == 0 || word.trailing.isEmpty else { break }
        name.insert(word, at: 0)
    }
    for start in name.indices {
        if let hit = flags.match(Array(name[start...])), hit.wordCount == name.count - start { return (hit.name, hit.wordCount) }
    }
    guard let last = name.last, !flagNameStops.contains(last.text.lowercased()) else { return nil }
    return (last.text.lowercased(), 1)
}

private func droppingConnectivesBeforeFlags(_ words: [Word]) -> [Word] {
    var kept: [Word] = []
    for word in words.reversed() {
        let beforeFlag = kept.last.map { $0.text.hasPrefix("-") && $0.text.count > 1 } ?? false
        if beforeFlag, ["the", "a", "an", "with"].contains(word.text.lowercased()) { continue }
        kept.append(word)
    }
    return kept.reversed()
}

/// Programs and subcommands a spoken command starts with. The engine writes them as names ("NPM", "Docker Compose", "LS").
let commandWords: Set<String> = [
    "git", "gh", "npm", "npx", "pnpm", "yarn", "bun", "node", "deno", "python", "python3", "pip", "pip3", "uv", "cargo",
    "go", "make", "docker", "compose", "kubectl", "brew", "swift", "xcodebuild", "ls", "cd", "cat", "grep", "rg", "find",
    "mkdir", "rm", "cp", "mv", "touch", "chmod", "curl", "ssh", "scp", "tar", "echo", "open", "code", "sudo", "claude",
    "status", "push", "pull", "commit", "log", "diff", "checkout", "add", "rebase", "merge", "fetch", "clone", "branch",
    "stash", "switch", "restore", "reset", "tag", "install", "run", "test", "build", "up", "down", "exec", "init",
]

/// After "get", these make it "git": the engine hears "git status" as "get status".
private let gitSubcommands: Set<String> = [
    "status", "push", "pull", "commit", "log", "diff", "checkout", "add", "rebase", "merge", "fetch", "clone", "branch",
    "stash", "switch", "restore", "reset", "tag", "init", "remote", "show", "blame",
]

private func commandWordsWritten(_ words: [Word]) -> [Word] {
    words.enumerated().map { i, word in
        let lower = word.text.lowercased()
        if lower == "get", i + 1 < words.count, gitSubcommands.contains(words[i + 1].text.lowercased()) {
            return Word(text: "git", trailing: word.trailing)
        }
        return commandWords.contains(lower) ? Word(text: lower, trailing: word.trailing) : word
    }
}

private func isLetter(_ word: Word) -> Bool { word.text.count == 1 && word.text.first?.isLetter == true }

/// Letters spoken one by one join into one lowercase word, split after a leading program ("C D S R C" is "cd src").
/// Letters right after "dash", "hyphen" or "flag" stay apart, since each is a short flag ("dash x f").
/// A lone letter is lowercase, because the engine capitalises it; "capital" before it keeps it upper case.
private func lettersWritten(_ words: [Word]) -> [Word] {
    var result: [Word] = []
    var i = 0
    while i < words.count {
        let word = words[i]
        let previous = result.last?.text.lowercased()
        if ["capital", "uppercase"].contains(word.text.lowercased()), i + 1 < words.count, isLetter(words[i + 1]) {
            result.append(Word(text: words[i + 1].text.uppercased(), trailing: words[i + 1].trailing))
            i += 2
            continue
        }
        guard isLetter(word), !["dash", "hyphen", "flag"].contains(previous ?? "") else {
            result.append(isLetter(word) ? Word(text: word.text.lowercased(), trailing: word.trailing) : word)
            i += 1
            continue
        }
        var end = i + 1
        while end < words.count, isLetter(words[end]), words[end - 1].trailing.isEmpty { end += 1 }
        let joined = words[i..<end].map { $0.text.lowercased() }.joined()
        let trailing = words[end - 1].trailing
        if let program = commandWords.filter({ joined.hasPrefix($0) && joined.count > $0.count }).max(by: { $0.count < $1.count }) {
            result.append(Word(text: program, trailing: ""))
            result.append(Word(text: String(joined.dropFirst(program.count)), trailing: trailing))
        } else {
            result.append(Word(text: joined, trailing: trailing))
        }
        i = end
    }
    return result
}

/// The engine capitalises each sentence's first word; a command does not. Words with other capitals
/// ("README", "PostgreSQL") and a single capital letter keep theirs.
private func lowercasingSentenceStarts(_ words: [Word]) -> [Word] {
    words.enumerated().map { i, word in
        let startsSentence = i == 0 || words[i - 1].endsSentence
        let sentenceCase = word.text.count > 1 && word.text.first?.isUppercase == true
            && word.text.dropFirst().allSatisfy { $0.isLetter && $0.isLowercase }
        return startsSentence && sentenceCase ? Word(text: word.text.lowercased(), trailing: word.trailing) : word
    }
}
