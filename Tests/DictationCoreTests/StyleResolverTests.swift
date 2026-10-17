import Testing
@testable import DictationCore

private func target(_ bundleID: String?, _ title: String? = nil, focus: String? = nil) -> DictationTarget {
    DictationTarget(bundleID: bundleID, appName: nil, windowTitle: title, focusedElement: focus)
}

struct StyleResolverTests {
    @Test(arguments: [
        (target("com.apple.Terminal", "✳ Fix the parser"), DictationStyle.claudeCode),
        (target("com.googlecode.iterm2", "claude — ~/code/app"), .claudeCode),
        (target("com.mitchellh.ghostty", "Claude Code"), .claudeCode),
        (target("com.anthropic.claudefordesktop", "Claude"), .claudeCode),
        (target("com.apple.Terminal", "roho7 — -zsh — 80×24"), .shell),
        (target("dev.warp.Warp-Stable", nil), .shell),
        (target("net.kovidgoyal.kitty", "vim notes.md"), .shell),
        (target("company.thebrowser.Browser", "(3) Feed | LinkedIn"), .formal),
        (target("com.google.Chrome", "Messaging | LinkedIn"), .formal),
        (target("com.apple.mail", "Inbox"), .formal),
        (target("com.apple.Safari", "GitHub"), .default),
        (target("com.todesktop.230313mzl4w4u92", "claude — dictation-app"), .default),
        (target("com.microsoft.VSCode", "zsh"), .default),
        (target("com.todesktop.230313mzl4w4u92", "app.ts", focus: "Terminal 1, zsh | xterm-helper-textarea"), .shell),
        (target("com.microsoft.VSCode", "app.ts", focus: "xterm-helper-textarea"), .shell),
        (target("com.todesktop.230313mzl4w4u92", "app.ts", focus: "Terminal 2, claude | xterm-helper-textarea"), .claudeCode),
        (target("com.todesktop.230313mzl4w4u92", "app.ts", focus: "Editor content | monaco-mouse-cursor-text"), .default),
        (target("com.apple.Safari", "Docs", focus: "Terminal 1, zsh | xterm-helper-textarea"), .default),
        (target(nil, nil), .default),
    ])
    func tableResolvesTargets(_ target: DictationTarget, _ style: DictationStyle) {
        #expect(resolveStyle(for: target).style == style)
    }

    @Test func overrideWinsOverTheTable() {
        let decision = resolveStyle(for: target("com.apple.Terminal", "zsh"), overrides: ["com.apple.Terminal": .claudeCode])
        #expect(decision == StyleDecision(style: .claudeCode, rule: "override for com.apple.Terminal"))
    }

    @Test func decisionNamesTheRule() {
        #expect(resolveStyle(for: target("com.apple.mail")).rule == "Mail")
        #expect(resolveStyle(for: target("com.apple.Notes")).rule == "any other app")
    }

    @Test func stylesParseFromTheirDefaultsSpelling() {
        #expect(["default", "claude-code", "shell", "formal", "loud"].map(DictationStyle.init(rawValue:))
            == [.default, .claudeCode, .shell, .formal, nil])
    }
}
