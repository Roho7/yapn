/// Matches spoken words to a known name by comparing letters and digits only,
/// so "grill me", "Grill-Me" and "grillme" all mean `grill-me`.
struct NameResolver {
    private let byKey: [String: String]

    init(names: [String]) {
        var byKey: [String: String] = [:]
        for name in names {
            let key = normalizedName(name)
            if !key.isEmpty, byKey[key] == nil { byKey[key] = name }
        }
        self.byKey = byKey
    }

    /// The longest run of leading words that spells a known name, or nil.
    func match(_ words: [Word]) -> (name: String, wordCount: Int)? {
        for count in stride(from: words.count, through: 1, by: -1) {
            let key = words.prefix(count).map { normalizedName($0.text) }.joined()
            if let name = byKey[key] { return (name, count) }
        }
        return nil
    }
}

func normalizedName(_ text: String) -> String {
    String(text.lowercased().filter { $0.isLetter || $0.isNumber })
}
