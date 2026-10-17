import AppKit

/// Reports Right Option press and release with the hardware event timestamp (seconds since boot).
/// The global monitor sees events aimed at other apps and needs Accessibility. The local one sees
/// events while our own menu is open. Left Option and every other modifier are ignored.
@MainActor
final class RightOptionMonitor {
    private static let rightOptionKeyCode: UInt16 = 61
    /// NX_DEVICERALTKEYMASK: the device-dependent bit for the right Option key alone.
    private static let rightOptionBit: UInt = 0x40

    private let onChange: (_ isDown: Bool, _ at: Double) -> Void
    private var monitors: [Any] = []
    private var isDown = false
    private var releaseWatch: Timer?

    init(onChange: @escaping (_ isDown: Bool, _ at: Double) -> Void) {
        self.onChange = onChange
    }

    func install() {
        uninstall()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { event in
            MainActor.assumeIsolated { self.handle(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            MainActor.assumeIsolated { self.handle(event) }
            return event
        }) { monitors.append(local) }
    }

    func uninstall() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == Self.rightOptionKeyCode else { return }
        set(down: event.modifierFlags.rawValue & Self.rightOptionBit != 0, at: event.timestamp)
    }

    private func set(down: Bool, at: Double) {
        guard down != isDown else { return }
        isDown = down
        onChange(down, at)
        down ? watchForMissedRelease() : stopWatching()
    }

    /// Secure Event Input (password fields, Terminal's Secure Keyboard Entry) hides key events from
    /// global monitors, which would leave the mic recording. Polling the live modifier state catches that.
    private func watchForMissedRelease() {
        releaseWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
                if UInt(flags) & Self.rightOptionBit == 0 {
                    self.set(down: false, at: ProcessInfo.processInfo.systemUptime)
                }
            }
        }
    }

    private func stopWatching() {
        releaseWatch?.invalidate()
        releaseWatch = nil
    }
}
