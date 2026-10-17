import AppKit
import DictationCore

/// `--selftest <wav>` drives the real pipeline without a microphone or a key press: a synthetic
/// Right Option hold, the WAV as the take, then transcribe, the formatting seam, and a real paste
/// into whatever app is frontmost. Prints one `SELFTEST` line and exits 0 only if something read the
/// pasted text, focus never moved, the clipboard came back byte for byte, and with history on the entry was saved.
/// `--no-paste` skips the paste, so it can run without touching the frontmost app.
@MainActor
func runSelfTest(_ controller: AppController, paste: Bool) async {
    while controller.state == .loading { try? await Task.sleep(for: .milliseconds(10)) }
    if case .failed(let reason) = controller.state { finish(false, ["error": reason]) }

    let frontBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
    let clipboardBefore = clipboardFingerprint()

    controller.send(.hotkeyDown(at: ProcessInfo.processInfo.systemUptime))
    try? await Task.sleep(for: .milliseconds(500))
    controller.send(.hotkeyUp(at: ProcessInfo.processInfo.systemUptime))
    while controller.state != .idle {
        if case .failed(let reason) = controller.state { finish(false, ["error": reason]) }
        try? await Task.sleep(for: .milliseconds(5))
    }

    let frontAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
    let clipboardRestored = clipboardFingerprint() == clipboardBefore
    let inserted = controller.last
    let pasteRead = inserted?.firstPasteboardReadMs
    let historyEntry = await controller.historyWrite?.value
    let historyOK = !controller.keepHistory || historyEntry != nil
    finish((!paste || pasteRead != nil) && clipboardRestored && frontBefore == frontAfter && historyOK, [
        "transcript": inserted?.text ?? "",
        "pasteboardReadAfterPasteMs": pasteRead.map { String(format: "%.1f", $0) } ?? "never",
        "releaseToPasteMs": inserted.map { String(format: "%.1f", $0.releaseToPasteMs) } ?? "",
        "clipboardRestored": "\(clipboardRestored)",
        "clipboardTypes": "\(clipboardBefore.flatMap(\.keys).sorted())",
        "frontmostBefore": frontBefore,
        "frontmostAfter": frontAfter,
        "pasted": "\(paste)",
        "history": historyEntry?.path ?? (controller.keepHistory ? "not saved" : "off"),
        "accessibilityTrusted": "\(Permission.accessibility.isGranted)",
        "menu": controller.menuTitles,
    ])
}

private func clipboardFingerprint() -> [[String: Data]] {
    (NSPasteboard.general.pasteboardItems ?? []).map { item in
        Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } })
    }
}

private func finish(_ passed: Bool, _ fields: [String: Any]) -> Never {
    let json = (try? JSONSerialization.data(withJSONObject: fields.merging(["passed": "\(passed)"]) { a, _ in a }, options: [.sortedKeys]))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    print("SELFTEST \(json)")
    fflush(stdout)
    exit(passed ? 0 : 1)
}
