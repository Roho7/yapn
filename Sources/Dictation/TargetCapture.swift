import AppKit
@preconcurrency import ApplicationServices
import DictationCore

/// The app a dictation will land in, read while it is still frontmost. Dictation never activates, so at
/// hotkey-down and while its menu is open the frontmost app is the user's. The window title comes through
/// the Accessibility grant the hotkey already needs; an app that does not answer within `axTimeout` gives none.
@MainActor
func captureTarget() -> DictationTarget {
    let app = NSWorkspace.shared.frontmostApplication
    return DictationTarget(
        bundleID: app?.bundleIdentifier,
        appName: app?.localizedName,
        windowTitle: app.flatMap { focusedWindowTitle(of: $0.processIdentifier) },
        focusedElement: app.flatMap { focusedElementLabel(of: $0) }
    )
}

/// Electron editors only build their accessibility tree once an assistive app asks with `AXManualAccessibility`.
/// Asking takes a moment to apply, so it is done when an editor activates, ahead of the first hotkey press.
@MainActor
func enableEditorAccessibilityOnActivation() {
    NSWorkspace.shared.runningApplications.forEach(enableAccessibilityIfEditor)
    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { note in
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            enableAccessibilityIfEditor(app)
        }
    }
}

private func enableAccessibilityIfEditor(_ app: NSRunningApplication) {
    guard editorApps.contains(app.bundleIdentifier ?? "") else { return }
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXManualAccessibility" as CFString, kCFBooleanTrue)
}

/// Only editors are asked: elsewhere the bundle id and window title are enough.
private func focusedElementLabel(of app: NSRunningApplication) -> String? {
    guard editorApps.contains(app.bundleIdentifier ?? "") else { return nil }
    enableAccessibilityIfEditor(app)
    let element = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(element, axTimeout)
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
    let focusedElement = focused as! AXUIElement
    var parts: [String] = []
    for attribute in ["AXDescription", "AXTitle", "AXDOMClassList"] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedElement, attribute as CFString, &value) == .success, let value else { continue }
        if let text = value as? String, !text.isEmpty { parts.append(text) }
        if let list = value as? [String] { parts.append(list.joined(separator: " ")) }
    }
    return parts.isEmpty ? nil : parts.joined(separator: " | ")
}

private let axTimeout: Float = 0.1

private func focusedWindowTitle(of pid: pid_t) -> String? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, axTimeout)
    var window: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
          let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
    var title: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
    return title as? String
}

/// `defaults write dev.roho.dictation styleOverrides -dict <bundle id> <style>`. Values that name no style are
/// returned so the caller can log them instead of failing silently.
func loadStyleOverrides() -> (overrides: [String: DictationStyle], invalid: [String]) {
    let raw = UserDefaults.standard.dictionary(forKey: "styleOverrides") ?? [:]
    var overrides: [String: DictationStyle] = [:]
    var invalid: [String] = []
    for (bundleID, value) in raw {
        if let name = value as? String, let style = DictationStyle(rawValue: name) {
            overrides[bundleID] = style
        } else {
            invalid.append("\(bundleID)=\(value)")
        }
    }
    return (overrides, invalid.sorted())
}
