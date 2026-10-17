/// Hesitation sounds the engine writes as words: "uh", "Umm", "erm", "hmm".
/// An all-caps token ("ER", "UM") is an acronym, so it never matches.
private var fillerPattern: Regex<Substring> { /(?:u+h+|u+h*m+|e+r+m+|er|a+h+|h+m+)/.ignoresCase() }

/// Words whose immediate repeat is almost never grammatical, so "the the" is a stutter.
/// "that that", "is is", "had had", "in in" ("log in in five minutes") can be real English and are left alone.
private let stutterWords: Set<String> = ["a", "an", "the", "to", "of", "and", "for", "with", "i"]

/// Words a speaker repeats on purpose or that the spoken-symbol and line-break rules read as words:
/// "very very very good", "no no no", "ha ha ha", "dot dot dot". Repeats of these are never collapsed or flagged.
let repeatExemptWords: Set<String> = {
    let spoken = (spokenSymbols.flatMap(\.phrases) + spokenBreaks.flatMap(\.phrases)).flatMap { $0 }
    return Set(spoken).union(["very", "really", "no", "yes", "ha", "haha", "blah", "la", "bye", "go"])
}()

/// Connectives that only ever lead into a next clause. "so", "then" and "like" are left out of the single-word
/// list because they end real sentences ("I think so", "see you then", "looks like").
private let danglingConnectives: Set<String> = ["and", "but", "or", "because"]

/// "and then", "but then", "so then": a "then" that leads into a clause that never came.
private let thenLeaders: Set<String> = ["and", "but", "or", "so"]

/// "words like uh and um": a filler joined to another filler by one of these is being talked about, not spoken.
private let mentionJoiners: Set<String> = ["and", "or"]

/// Drops hesitation sounds and immediate stutters before any other rule sees the words,
/// so "dash dash uh verbose" reaches the flag rule as "dash dash verbose".
/// A dropped filler takes its comma with it and leaves the word before it alone:
/// "So, uh, I need" becomes "So, I need". A full stop on the filler moves to the word before it.
func removeDisfluencies(_ words: [Word]) -> [Word] {
    var kept: [Word] = []
    var capitaliseNext = false
    for (i, word) in words.enumerated() {
        if isFiller(word), !isMentioned(i, in: words) {
            let startsSentence = kept.last?.endsSentence ?? true
            if startsSentence, word.text.first?.isUppercase == true { capitaliseNext = true }
            if word.endsSentence, let last = kept.last, !last.endsSentence {
                kept[kept.count - 1] = Word(text: last.text, trailing: word.trailing)
            }
            continue
        }
        let word = capitaliseNext ? Word(text: capitalisedIfPlain(word.text), trailing: word.trailing) : word
        capitaliseNext = false
        if let last = kept.last, last.trailing.isEmpty,
           last.text.lowercased() == word.text.lowercased(), stutterWords.contains(word.text.lowercased()) {
            kept[kept.count - 1] = Word(text: last.text, trailing: word.trailing)
            continue
        }
        kept.append(word)
    }
    return dropDanglingEnd(collapseLongRepeats(kept))
}

/// True for a word made of letters and apostrophes: "it's" and "we're", not "auth.ts" or "3".
func isPlainWord(_ text: String) -> Bool {
    text.contains(where: \.isLetter) && text.allSatisfy { $0.isLetter || $0 == "'" || $0 == "\u{2019}" }
}

/// Three or more bare repeats of a word, or of a two-word phrase, collapse to one:
/// "it's it's it's it's" is "it's" and "I think I think I think" is "I think".
/// A punctuation mark between repeats ("no, no, no") shows the speaker meant it, and `repeatExemptWords` stay.
/// Two repeats are left to `stutterWords` and the cleaner, because "that that" can be grammatical.
private func collapseLongRepeats(_ words: [Word]) -> [Word] {
    [1, 2].reduce(words) { collapseRepeats(of: $1, in: $0) }
}

private func collapseRepeats(of period: Int, in words: [Word]) -> [Word] {
    func unit(at start: Int) -> [String]? {
        guard start + period <= words.count else { return nil }
        let slice = words[start..<start + period]
        guard slice.dropLast().allSatisfy({ $0.trailing.isEmpty }) else { return nil }
        let lowered = slice.map { $0.text.lowercased() }
        return lowered.allSatisfy { isPlainWord($0) && !repeatExemptWords.contains($0) } ? lowered : nil
    }
    var result: [Word] = []
    var i = 0
    while i < words.count {
        guard let phrase = unit(at: i) else {
            result.append(words[i])
            i += 1
            continue
        }
        var end = i + period
        var count = 1
        while words[end - 1].trailing.isEmpty, unit(at: end) == phrase {
            end += period
            count += 1
        }
        if count >= 3 {
            result += words[i..<i + period - 1]
            result.append(Word(text: words[i + period - 1].text, trailing: words[end - 1].trailing))
            i = end
        } else {
            result.append(words[i])
            i += 1
        }
    }
    return result
}

/// A connective that ends the whole dictation has nothing to connect to: "cleaning up everything properly and".
/// It goes, and so does the comma before it. A full stop the engine put on it moves to the word before.
/// No punctuation is invented: with none to carry, the text stays unpunctuated.
/// "because" must be bare ("Why? Because." is an answer); a lone connective is kept.
private func dropDanglingEnd(_ words: [Word]) -> [Word] {
    var kept = words
    while let count = danglingCount(in: kept), kept.count > count {
        let dropped = kept[kept.count - 1]
        kept.removeLast(count)
        let before = kept.removeLast()
        var trailing = before.trailing
        while let last = trailing.last, ",;:".contains(last) { trailing.removeLast() }
        if trailing.isEmpty, dropped.endsSentence { trailing = dropped.trailing }
        kept.append(Word(text: before.text, trailing: trailing))
    }
    return kept
}

private func danglingCount(in words: [Word]) -> Int? {
    guard let last = words.last else { return nil }
    let text = last.text.lowercased()
    let leadsOn = last.trailing.isEmpty || last.trailing == "." || last.trailing == ","
    if text == "then", leadsOn, words.count >= 2, words[words.count - 2].trailing.isEmpty,
       thenLeaders.contains(words[words.count - 2].text.lowercased()) {
        return 2
    }
    if danglingConnectives.contains(text), text == "because" ? last.trailing.isEmpty : leadsOn { return 1 }
    return nil
}

private func isFiller(_ word: Word) -> Bool {
    let isAcronym = word.text.count > 1 && word.text == word.text.uppercased()
    return !isAcronym && word.text.wholeMatch(of: fillerPattern) != nil
}

private func isMentioned(_ index: Int, in words: [Word]) -> Bool {
    func joined(_ joiner: Int, _ other: Int) -> Bool {
        words.indices.contains(joiner) && words.indices.contains(other)
            && mentionJoiners.contains(words[joiner].text.lowercased()) && isFiller(words[other])
    }
    return joined(index + 1, index + 2) || joined(index - 1, index - 2)
}

/// Upper-cases the first letter of a plain lowercase word; "useAuth", "src/lib" and "--verbose" keep their case.
func capitalisedIfPlain(_ text: String) -> String {
    let head = text.prefix { !$0.isWhitespace }.trimmingSuffix { sentencePunctuation.contains($0) }
    guard let first = head.first, head.allSatisfy({ $0.isLetter && $0.isLowercase }) else { return text }
    return first.uppercased() + text.dropFirst()
}

private extension Substring {
    func trimmingSuffix(while drop: (Character) -> Bool) -> Substring {
        var result = self
        while let last = result.last, drop(last) { result.removeLast() }
        return result
    }
}
