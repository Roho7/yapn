import AppKit

/// Where the indicator grows from: the notch on a screen that has one, otherwise a point on the menu bar.
struct NotchGeometry: Equatable {
    /// The screen's frame in global coordinates.
    let screenFrame: CGRect
    /// The notch's horizontal centre in global coordinates.
    let midX: CGFloat
    /// The notch's size. Width is 0 on a screen without a notch.
    let notch: CGSize

    var hasNotch: Bool { notch.width > 0 }

    @MainActor
    static func current() -> NotchGeometry {
        for screen in NSScreen.screens where screen.safeAreaInsets.top > 0 {
            guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { continue }
            // The auxiliary areas start at the screen's left edge. Whether AppKit reports them in global
            // or screen-local coordinates is undocumented, so detect which from that edge.
            let originX = abs(left.minX - screen.frame.minX) < 1 ? 0 : screen.frame.minX
            return NotchGeometry(
                screenFrame: screen.frame,
                midX: originX + (left.maxX + right.minX) / 2,
                notch: CGSize(width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
            )
        }
        let screen = NSScreen.screens.first ?? NSScreen.main
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let menuBar = screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0
        return NotchGeometry(
            screenFrame: frame,
            midX: frame.midX,
            notch: CGSize(width: 0, height: menuBar > 0 ? menuBar : NSStatusBar.system.thickness)
        )
    }
}
