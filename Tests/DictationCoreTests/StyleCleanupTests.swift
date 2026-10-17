import Testing
@testable import DictationCore

private struct EchoInstructions: TranscriptCleaner {
    let output: String
    func clean(_ text: String, instructions: String) async throws -> String {
        instructions == formalInstructions || instructions == shellInstructions ? output : "wrong instructions"
    }
}

struct FormalCleanupTests {
    @Test func fluentTextStillReachesTheModel() async {
        let result = await cleanup("Thanks for the intro.", with: EchoInstructions(output: "Thanks for the intro."), style: .formal)
        #expect(result.outcome == .accepted("Thanks for the intro."))
    }

    @Test func crutchesIntensifiersAndOpeningConjunctionsMayGo() {
        #expect(reviewCleanup(
            input: "And so I just wanted to say, like, we're really proud of the team.",
            output: "I wanted to say we're proud of the team.",
            formal: true
        ) == nil)
        #expect(reviewCleanup(input: "But like, the launch went well.", output: "The launch went well.", formal: true) == nil)
    }

    @Test func formalRejectsAModelThatShoutsButKeepsAcronyms() {
        let input = "We're hiring two engineers for the platform team."
        #expect(reviewCleanup(input: input, output: "WE'RE HIRING TWO ENGINEERS FOR THE PLATFORM TEAM.", formal: true) == .shouting)
        #expect(reviewCleanup(input: "we're hiring for the api team", output: "We're hiring for the API team.", formal: true) == nil)
        #expect(reviewCleanup(input: "READ THE API DOCS", output: "READ THE API DOCS.", formal: true) == nil)
    }

    @Test func caseAndPunctuationChangesAreTheEdit() {
        #expect(reviewCleanup(input: "thanks maria. see you monday", output: "Thanks, Maria. See you Monday.", formal: true) == nil)
        #expect(reviewCleanup(input: "thanks maria. see you monday", output: "Thanks, Maria. See you Monday.") == .cosmeticOnly)
    }

    @Test func meaningfulWordsAndQuestionsStay() {
        #expect(reviewCleanup(input: "We shipped the new billing flow.", output: "We shipped the flow.", formal: true)
            == .deletedWords(["new", "billing"]))
        #expect(reviewCleanup(input: "Are you free on Monday?", output: "Let me know if you are free on Monday.", formal: true)
            == .droppedQuestionMark)
        #expect(reviewCleanup(input: "Great post.", output: "Great post! Thanks for sharing this insight.", formal: true)
            == .addedWords(["thanks", "for", "sharing", "this", "insight"]))
    }

    @Test func codeTokensStayVerbatim() {
        #expect(reviewCleanup(input: "we moved to src/lib/auth.ts", output: "We moved to the auth module.", formal: true)
            == .droppedToken("src/lib/auth.ts"))
    }
}

struct ShellCleanupTests {
    @Test func commitMessageBecomesDashM() async {
        let result = await cleanup(
            "git commit with message fix login bug", with: EchoInstructions(output: "git commit -m \"fix login bug\""), style: .shell
        )
        #expect(result.outcome == .accepted("git commit -m \"fix login bug\""))
    }

    @Test func commandWithNoConnectiveSkipsTheModel() async {
        let result = await cleanup("git status", with: EchoInstructions(output: "git status --short"), style: .shell)
        #expect(result.outcome == .skipped)
        #expect(!mayNeedShellCleanup("npm run build"))
        #expect(mayNeedShellCleanup("run git log --oneline"))
    }

    @Test(arguments: [
        ("run git log with --oneline", "git log --oneline"),
        ("run npm test with the verbose option", "npm test --verbose"),
        ("make build", "make build"),
    ])
    func deletingConnectivesIsAccepted(_ input: String, _ output: String) {
        #expect(reviewShellCommand(input: input, output: output) == nil)
    }

    @Test(arguments: [
        ("run the tests with --verbose", "npm test -- --verbose", CleanupRejection.addedWords(["npm"])),
        ("npm run build", "npm build", .deletedWords(["run"])),
        ("git push origin main", "git push", .deletedWords(["origin", "main"])),
        ("list the files", "ls -la", .addedWords(["ls"])),
        ("git status and git diff", "git status && git diff", .addedWords(["&&"])),
        ("git commit with message wip", "git commit -m \"wip", .unbalancedQuotes),
        ("echo hi with the newline", "echo hi\n", .multiline),
    ])
    func inventedOrDroppedCommandPartsAreRejected(_ input: String, _ output: String, _ rejection: CleanupRejection) {
        #expect(reviewShellCommand(input: input, output: output) == rejection)
    }

    @Test func wrappingIsRemovedBeforeReview() {
        #expect(unwrappedCommand("`git status`") == "git status")
        #expect(unwrappedCommand("$ git status\n") == "git status")
    }

    @Test func shellPasteIsOneLineWithNoTrailingNewline() {
        #expect(pasteText("git status\n", style: .shell) == "git status")
        #expect(pasteText("ls\n-la", style: .shell) == "ls -la")
        #expect(pasteText("Steps:\n- build", style: .default) == "Steps:\n- build")
    }
}
