import AppKit
import DictationCore

struct LastDictation {
    let text: String
    let releaseToPasteMs: Double
    /// Nil when nothing read the pasteboard before it was restored, so the paste did not land.
    let firstPasteboardReadMs: Double?
}

/// The menu bar item. It is rebuilt from scratch on every state change and every time it opens,
/// so it never holds state of its own.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let snapshot: () -> (DictationState, LastDictation?, cleanup: CleanupMenu, styleLine: String, keepHistory: Bool)
    private let onMenuOpen: () -> Void
    private let onToggleHistory: () -> Void
    private let onToggleCleanup: () -> Void

    init(
        snapshot: @escaping () -> (DictationState, LastDictation?, cleanup: CleanupMenu, styleLine: String, keepHistory: Bool),
        onMenuOpen: @escaping () -> Void,
        onToggleHistory: @escaping () -> Void,
        onToggleCleanup: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.onMenuOpen = onMenuOpen
        self.onToggleHistory = onToggleHistory
        self.onToggleCleanup = onToggleCleanup
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        render()
    }

    var titles: [String] { menu.items.map { $0.isSeparatorItem ? "---" : $0.title } }

    func menuNeedsUpdate(_ menu: NSMenu) {
        onMenuOpen()
        render()
    }

    func render() {
        let (state, last, cleanup, styleLine, keepHistory) = snapshot()
        item.button?.image = Self.image(for: state)

        menu.removeAllItems()
        menu.addItem(disabled(Self.stateLine(for: state)))
        menu.addItem(.separator())
        if let last {
            let preview = last.text.count > 60 ? last.text.prefix(60) + "…" : last.text
            menu.addItem(disabled("Last: \(preview)"))
            menu.addItem(disabled(String(format: "Release to paste: %.0f ms", last.releaseToPasteMs)))
            menu.addItem(action("Copy Last", #selector(copyLast), represented: last.text))
        } else {
            menu.addItem(disabled("No dictation yet"))
        }
        menu.addItem(.separator())
        menu.addItem(disabled(styleLine))
        let cleanupToggle = action("Smart cleanup", #selector(toggleCleanup), represented: nil)
        cleanupToggle.state = switch cleanup.mark { case .off: .off; case .on: .on; case .waiting: .mixed }
        cleanupToggle.toolTip = Self.cleanupHelp
        menu.addItem(cleanupToggle)
        if let detail = cleanup.detail {
            let line = disabled(detail)
            line.indentationLevel = 1
            menu.addItem(line)
        }
        if cleanup.offersAppleIntelligenceSettings {
            let open = action("Turn On Apple Intelligence…", #selector(openSettings), represented: Self.appleIntelligenceSettings)
            open.indentationLevel = 1
            menu.addItem(open)
        }
        for permission in Permission.allCases {
            if permission.isGranted {
                menu.addItem(disabled("\(permission.name): allowed"))
            } else {
                menu.addItem(action("\(permission.name) needed \(permission.purpose)…", #selector(openSettings), represented: permission.settingsURL))
            }
        }
        menu.addItem(.separator())
        let historyToggle = action("Keep dictation history", #selector(toggleHistory), represented: nil)
        historyToggle.state = keepHistory ? .on : .off
        historyToggle.toolTip = Self.historyPrivacy
        menu.addItem(historyToggle)
        let historyFolder = action("Open History Folder", #selector(openHistoryFolder), represented: nil)
        historyFolder.toolTip = Self.historyPrivacy
        menu.addItem(historyFolder)
        menu.addItem(.separator())
        menu.addItem(action("Quit Yapn", #selector(quit), represented: nil, key: "q"))
    }

    private static let appleIntelligenceSettings = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!

    private static let cleanupHelp = "Fixes self-corrections and hesitation using Apple Intelligence. "
        + "Needs macOS 26 with Apple Intelligence on. It runs on this Mac and only steps in when your words need it."

    private static let historyPrivacy = "Saves each dictation's audio and text in ~/Library/Application Support/Yapn/history "
        + "so `bench label` can turn them into your eval set. It stays on this Mac and is never uploaded."

    private static func stateLine(for state: DictationState) -> String {
        switch state {
        case .loading: "Loading model…"
        case .idle: "Ready. Hold Right Option to dictate"
        case .recording: "Listening…"
        case .transcribing: "Transcribing…"
        case .inserting: "Inserting…"
        case .failed(let reason): "Error: \(reason)"
        }
    }

    /// The bundled glyph for normal use; loading and failure keep their system symbols so they stand out.
    /// Recording and transcribing are shown by the notch, so the menu bar stays calm.
    private static let menuIcon: NSImage? = {
        guard let image = Bundle.main.image(forResource: "MenuIcon") else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = "Yapn"
        return image
    }()

    private static func image(for state: DictationState) -> NSImage? {
        switch state {
        case .loading, .failed: break
        case .idle, .recording, .transcribing, .inserting:
            if let menuIcon { return menuIcon }
        }
        return NSImage(systemSymbolName: symbol(for: state), accessibilityDescription: "Yapn")
    }

    private static func symbol(for state: DictationState) -> String {
        switch state {
        case .loading: "hourglass"
        case .idle: "mic"
        case .recording: "mic.fill"
        case .transcribing, .inserting: "waveform"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, represented: Any?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.representedObject = represented
        return item
    }

    @objc private func copyLast(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleHistory() {
        onToggleHistory()
    }

    @objc private func toggleCleanup() {
        onToggleCleanup()
    }

    @objc private func openHistoryFolder() {
        let directory = HistoryStore.defaultDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
