/// Where a dictation is going, as the app saw it when Right Option went down and the target app was still frontmost.
public struct DictationTarget: Sendable, Equatable, Codable {
    public let bundleID: String?
    public let appName: String?
    /// The focused window's title through the Accessibility API: a browser's tab title, a terminal's title.
    public let windowTitle: String?
    /// The focused element's accessibility label and DOM classes, joined: how an editor's integrated
    /// terminal ("Terminal 1, zsh", class `xterm-helper-textarea`) is told apart from its text editor.
    public let focusedElement: String?

    public init(bundleID: String?, appName: String?, windowTitle: String?, focusedElement: String? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.focusedElement = focusedElement
    }

    /// VS Code-family editors render their terminal with xterm.js, whose input is a textarea labelled "Terminal N, <process>".
    var isEditorTerminalFocused: Bool {
        guard let focus = focusedElement?.lowercased() else { return false }
        return focus.contains("xterm") || focus.hasPrefix("terminal")
    }
}

/// How a dictation is written for the app it lands in.
public enum DictationStyle: String, CaseIterable, Sendable, Codable {
    /// Prose and dev prompts: the rules, then cleanup only when the text shows a correction, restart, heavy hesitation or list.
    case `default`
    /// Claude Code, in a terminal or the Claude app. Written exactly as `default`: the prompt pipeline was built for it.
    case claudeCode = "claude-code"
    /// A shell prompt: the text is a command line, single-line and unpunctuated, never with a newline that would run it.
    case shell
    /// LinkedIn and Mail: capitalised, punctuated sentences without crutch words or stacked conjunctions.
    case formal

    public var name: String {
        switch self {
        case .default: "Default"
        case .claudeCode: "Claude Code"
        case .shell: "Shell"
        case .formal: "Formal"
        }
    }
}

/// The style a target resolved to and the rule that chose it, so the log and menu can say why.
public struct StyleDecision: Sendable, Equatable {
    public let style: DictationStyle
    public let rule: String
}

/// One row of the resolver table: the apps it covers (any app when nil) and, if set, words one of which the
/// window title must contain, case-insensitively.
struct StyleRule {
    let name: String
    let style: DictationStyle
    let apps: Set<String>?
    var titleContains: [String]? = nil
    /// Set for editor rules: the focused element must be the integrated terminal, and if `focusContains`
    /// is set its label must also name one of these processes.
    var needsEditorTerminal = false
    var focusContains: [String]? = nil

    func matches(_ target: DictationTarget) -> Bool {
        if let apps, !apps.contains(target.bundleID ?? "") { return false }
        if needsEditorTerminal, !target.isEditorTerminalFocused { return false }
        if let focusContains {
            let focus = (target.focusedElement ?? "").lowercased()
            guard focusContains.contains(where: focus.contains) else { return false }
        }
        guard let titleContains else { return true }
        let title = (target.windowTitle ?? "").lowercased()
        return titleContains.contains { title.contains($0) }
    }
}

/// Terminal emulators.
let terminalApps: Set<String> = [
    "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
    "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
]

/// VS Code-family editors. Their integrated terminal is recognised from the focused element, not the bundle id.
public let editorApps: Set<String> = [
    "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
    "com.exafunction.windsurf", "com.vscodium",
]

let browserApps: Set<String> = [
    "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "company.thebrowser.dia",
    "org.mozilla.firefox", "com.brave.Browser", "com.microsoft.edgemac",
]

/// Claude Code titles its terminal with "claude" or, while it works, a "✳"-family spinner glyph.
let claudeCodeTitleMarks = ["claude", "✳", "✶", "✻", "✽", "✢"]

/// Ordered; the first match wins.
let styleRules: [StyleRule] = [
    StyleRule(name: "Claude Code in a terminal", style: .claudeCode, apps: terminalApps, titleContains: claudeCodeTitleMarks),
    StyleRule(name: "Claude app", style: .claudeCode, apps: ["com.anthropic.claudefordesktop"]),
    StyleRule(name: "terminal", style: .shell, apps: terminalApps),
    StyleRule(name: "Claude Code in an editor terminal", style: .claudeCode, apps: editorApps, needsEditorTerminal: true, focusContains: ["claude"]),
    StyleRule(name: "editor terminal", style: .shell, apps: editorApps, needsEditorTerminal: true),
    StyleRule(name: "LinkedIn in a browser", style: .formal, apps: browserApps, titleContains: ["linkedin"]),
    StyleRule(name: "Mail", style: .formal, apps: ["com.apple.mail"]),
    StyleRule(name: "any other app", style: .default, apps: nil),
]

/// `overrides` maps a bundle id to a style and wins over the table:
/// `defaults write dev.roho.yapn styleOverrides -dict com.apple.Terminal claude-code`.
public func resolveStyle(for target: DictationTarget, overrides: [String: DictationStyle] = [:]) -> StyleDecision {
    if let bundleID = target.bundleID, let style = overrides[bundleID] {
        return StyleDecision(style: style, rule: "override for \(bundleID)")
    }
    let rule = styleRules.first { $0.matches(target) } ?? styleRules[styleRules.count - 1]
    return StyleDecision(style: rule.style, rule: rule.name)
}
