import Testing
@testable import DictationCore

struct PromptFileTests {
    @Test func parsesMultiCategoryFixture() throws {
        let text = """
        # Dev prompts
        # category: path
        open `src/lib/auth.ts` and refactor `useAuthProvider`

        # category: flag
        add a `--dry-run` flag to the deploy script
        # a stray comment
        # category: prose
        the meeting went well
        """

        let prompts = try PromptFile.parse(text)

        #expect(prompts == [
            Prompt(id: 1, category: .path, written: "open src/lib/auth.ts and refactor useAuthProvider", tokens: ["src/lib/auth.ts", "useAuthProvider"]),
            Prompt(id: 2, category: .flag, written: "add a --dry-run flag to the deploy script", tokens: ["--dry-run"]),
            Prompt(id: 3, category: .prose, written: "the meeting went well", tokens: []),
        ])
    }

    @Test func utteranceBeforeAnyCategoryReportsItsLine() {
        #expect(throws: PromptFileError.utteranceBeforeCategory(line: 3)) {
            try PromptFile.parse("# notes\n\nrun `/init`\n# category: skill\n")
        }
    }

    @Test func unknownCategoryReportsItsLine() {
        #expect(throws: PromptFileError.unknownCategory("poetry", line: 2)) {
            try PromptFile.parse("# category: skill\n# category: poetry\n")
        }
    }

    @Test func unbalancedBackticksReportTheirLine() {
        #expect(throws: PromptFileError.unbalancedBackticks(line: 3)) {
            try PromptFile.parse("# category: skill\nrun `/init`\nrun `/code-review on this\n")
        }
    }

    @Test func emptyBacktickPairIsRejected() {
        #expect(throws: PromptFileError.emptyToken(line: 2)) {
            try PromptFile.parse("# category: skill\nrun `` now\n")
        }
    }

    @Test func realPromptFileCoversEveryCategory() throws {
        let text = try readRepoFile("data/prompts.txt")

        let prompts = try PromptFile.parse(text)

        #expect(prompts.count >= 30)
        for category in PromptCategory.allCases {
            #expect(prompts.filter { $0.category == category }.count >= 4, "category \(category.rawValue)")
        }
        #expect(prompts.map(\.id) == Array(1...prompts.count))
        #expect(prompts.filter { $0.category == .prose }.allSatisfy { $0.tokens.isEmpty })
    }
}
