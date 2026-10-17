import Testing
@testable import DictationCore

struct SpokenWordsTests {
    @Test func identifierSpokenAndCasedFormsNormaliseAlike() {
        let expected = ["use", "auth", "provider"]
        #expect(spokenWords("useAuthProvider") == expected)
        #expect(spokenWords("use auth provider") == expected)
        #expect(spokenWords("Use Auth Provider.") == expected)
        #expect(spokenWords("UseAuthProvider") == expected)
        #expect(spokenWords("use_auth_provider") == expected)
        #expect(spokenWords("use-auth-provider") == expected)
    }

    @Test func symbolsBecomeSpokenWords() {
        #expect(spokenWords("src/lib/auth.ts") == ["src", "slash", "lib", "slash", "auth", "dot", "ts"])
        #expect(spokenWords("/code-review") == ["slash", "code", "review"])
        #expect(spokenWords("--dry-run") == ["dash", "dash", "dry", "run"])
        #expect(spokenWords("add -c now") == ["add", "dash", "c", "now"])
    }

    @Test func punctuationIsStrippedAndDigitsKept() {
        #expect(spokenWords("Don't stop, version 3.5!") == ["dont", "stop", "version", "3", "dot", "5"])
        #expect(spokenWords("URLSession and CLAUDE.md") == ["url", "session", "and", "claude", "dot", "md"])
        #expect(spokenWords("a - b") == ["a", "b"])
    }
}

struct WordErrorRateTests {
    @Test func identicalAfterNormalisationIsZero() {
        #expect(wordErrorRate(reference: "refactor useAuthProvider", hypothesis: "Refactor use auth provider.") == 0)
    }

    @Test func countsDeletion() {
        let edits = wordEdits(reference: "open the file", hypothesis: "open file")
        #expect(edits == WordEdits(substitutions: 0, deletions: 1, insertions: 0, referenceLength: 3))
        #expect(edits.rate == 1.0 / 3.0)
    }

    @Test func countsInsertion() {
        let edits = wordEdits(reference: "run the tests", hypothesis: "run the best tests")
        #expect(edits == WordEdits(substitutions: 0, deletions: 0, insertions: 1, referenceLength: 3))
    }

    @Test func countsSubstitutionAndDeletion() {
        let edits = wordEdits(reference: "use auth provider now", hypothesis: "use off provider")
        #expect(edits == WordEdits(substitutions: 1, deletions: 1, insertions: 0, referenceLength: 4))
        #expect(wordErrorRate(reference: "use auth provider now", hypothesis: "use off provider") == 0.5)
    }

    @Test func emptyHypothesisDeletesEverything() {
        let edits = wordEdits(reference: "one two three four", hypothesis: "")
        #expect(edits == WordEdits(substitutions: 0, deletions: 4, insertions: 0, referenceLength: 4))
        #expect(edits.rate == 1)
    }

    @Test func corpusRateWeightsByReferenceLengthNotClipCount() {
        let short = wordEdits(reference: "go", hypothesis: "no")
        let long = wordEdits(reference: "one two three four five six seven eight nine ten", hypothesis: "one two three four five six seven eight nine ten")
        #expect(short.rate == 1)
        #expect((short + long) == WordEdits(substitutions: 1, deletions: 0, insertions: 0, referenceLength: 11))
        #expect((short + long).rate == 1.0 / 11.0)
    }
}

struct TokenHitTests {
    @Test func lenientAcceptsSpokenFormOfIdentifier() {
        #expect(tokenHit("useAuthProvider", in: "use auth provider", mode: .lenient))
    }

    @Test func strictRejectsSpokenFormOfIdentifier() {
        #expect(!tokenHit("useAuthProvider", in: "use auth provider", mode: .strict))
    }

    @Test func strictAcceptsVerbatimToken() {
        #expect(tokenHit("useAuthProvider", in: "please refactor useAuthProvider today", mode: .strict))
        #expect(tokenHit("useAuthProvider", in: "please refactor useAuthProvider today", mode: .lenient))
    }

    @Test func lenientIgnoresCaseAndPunctuation() {
        #expect(tokenHit("--dry-run", in: "add a dry run flag", mode: .lenient))
        #expect(tokenHit("/code-review", in: "Run slash code review.", mode: .lenient))
    }

    // Documented spec behaviour: lenient only strips spaces and punctuation, it does not
    // expand spoken symbols, so "slash" and "dot" never match `/` and `.`.
    @Test func spelledOutPathIsALenientMiss() {
        let spoken = "source slash lib slash auth dot ts"
        #expect(!tokenHit("src/lib/auth.ts", in: spoken, mode: .lenient))
        #expect(!tokenHit("src/lib/auth.ts", in: spoken, mode: .strict))
    }

    @Test func verbatimPathIsAStrictHit() {
        #expect(tokenHit("src/lib/auth.ts", in: "open src/lib/auth.ts now", mode: .strict))
        #expect(tokenHit("src/lib/auth.ts", in: "open src/lib/auth.ts now", mode: .lenient))
    }
}

struct ScoreTests {
    private let prompt = Prompt(
        id: 7,
        category: .path,
        written: "open src/lib/auth.ts and refactor useAuthProvider",
        tokens: ["src/lib/auth.ts", "useAuthProvider"]
    )

    @Test func scoresWordsAndTokensTogether() {
        let clip = score(prompt: prompt, transcript: "open source slash lib slash auth dot ts and refactor use auth provider")

        #expect(clip.promptID == 7)
        #expect(clip.category == .path)
        #expect(clip.words == WordEdits(substitutions: 1, deletions: 0, insertions: 0, referenceLength: 13))
        #expect(clip.hitCount(.lenient) == 1)
        #expect(clip.hitCount(.strict) == 0)
        #expect(clip.missedTokens(.lenient) == ["src/lib/auth.ts"])
        #expect(clip.missedTokens(.strict) == ["src/lib/auth.ts", "useAuthProvider"])
    }

    @Test func perfectTranscriptHitsEverythingStrictly() {
        let clip = score(prompt: prompt, transcript: "open src/lib/auth.ts and refactor useAuthProvider")

        #expect(clip.words.errors == 0)
        #expect(clip.hitCount(.strict) == 2)
        #expect(clip.missedTokens(.lenient) == [])
    }

    @Test func proseClipHasNoTokensToScore() {
        let prose = Prompt(id: 1, category: .prose, written: "the meeting went well", tokens: [])
        let clip = score(prompt: prose, transcript: "the meeting went well")

        #expect(clip.tokens.isEmpty)
        #expect(clip.words.rate == 0)
    }
}

struct FalseInsertionTests {
    private let vocabulary = ["/compact", "/review", "--force", "/grill-me"]

    @Test func countsATermTheReferenceDoesNotHave() {
        let inserted = falseInsertions(vocabulary: vocabulary, reference: "compare tsconfig.json with package.json", hypothesis: "/compact tsconfig.json with package.json")
        #expect(inserted == ["/compact"])
    }

    @Test func aTermTheReferenceAlsoHasIsNotFalse() {
        #expect(falseInsertions(vocabulary: vocabulary, reference: "run /compact now", hypothesis: "Run /compact now.") == [])
    }

    @Test func countsEachExtraOccurrence() {
        #expect(falseInsertions(vocabulary: vocabulary, reference: "run /review", hypothesis: "/review then /review") == ["/review"])
    }

    @Test func aTermInsideALongerNameDoesNotCount() {
        let inserted = falseInsertions(vocabulary: vocabulary, reference: "push", hypothesis: "push --force-with-lease to src/review")
        #expect(inserted == [])
    }

    @Test func clipScoreCarriesItsInsertions() {
        let prompt = Prompt(id: 17, category: .path, written: "compare tsconfig.json with package.json", tokens: ["tsconfig.json", "package.json"])
        let clip = score(prompt: prompt, transcript: "/compact tsconfig.json with /grill-me", vocabulary: vocabulary)
        #expect(clip.falseInsertions == ["/compact", "/grill-me"])
    }
}

struct WorseCountTests {
    @Test func countsOnlyClipsTheStageLeftWithMoreWordEdits() {
        let steps = [
            StageStep(reference: "meet Tuesday", input: "meet Monday no wait Tuesday", output: "meet Tuesday"),
            StageStep(reference: "run the tests", input: "run the tests", output: "run tests"),
            StageStep(reference: "open the file", input: "open a file", output: "open file"),
            StageStep(reference: "ship it", input: "ship it", output: "Ship it."),
        ]

        #expect(steps.map(\.madeWorse) == [false, true, false, false])
        #expect(worseCount(steps) == 1)
    }

    @Test func swappingOneErrorForAnotherIsNotWorse() {
        #expect(worseCount([StageStep(reference: "a b c", input: "a x c", output: "a b y")]) == 0)
        #expect(worseCount([StageStep(reference: "a b c", input: "a x c", output: "a y z")]) == 1)
    }
}
