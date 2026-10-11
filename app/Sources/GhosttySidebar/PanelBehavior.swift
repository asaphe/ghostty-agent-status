import AppKit

final class SidebarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum PanelCoverage {
    static func blocks(owner: pid_t?, layer: Int?, alpha: Double, frame: CGRect?,
                       sidebar: CGRect, ownPID: pid_t) -> Bool {
        guard let owner, owner != ownPID,
              layer == 0, alpha > 0, let frame else { return false }
        return frame.intersects(sidebar)
    }
}

enum WindowScan {
    static func isComplete(expected: [CGWindowID], matched: [CGWindowID]) -> Bool {
        expected.sorted() == matched.sorted()
    }
}
