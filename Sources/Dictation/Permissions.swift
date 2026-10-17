import AppKit
@preconcurrency import ApplicationServices
import AVFoundation

enum Permission: CaseIterable {
    case microphone
    case accessibility

    var name: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        }
    }

    var settingsURL: URL {
        switch self {
        case .microphone: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }

    var isGranted: Bool {
        switch self {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility: AXIsProcessTrusted()
        }
    }

    /// Why the app needs it, shown next to a missing grant.
    var purpose: String {
        switch self {
        case .microphone: "to hear you"
        case .accessibility: "for the Right Option hotkey and pasting"
        }
    }
}

/// Shows the system prompts for anything not yet decided. Missing grants stay listed in the menu.
@MainActor
func requestPermissions() async {
    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
}
