import AppKit

@main
struct PanelTests {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let panel = SidebarPanel(contentRect: CGRect(x: 0, y: 0, width: 280, height: 600),
                                 styleMask: [.titled, .nonactivatingPanel, .utilityWindow],
                                 backing: .buffered, defer: false)
        precondition(!panel.canBecomeKey && !panel.canBecomeMain)
        panel.makeKey()
        precondition(!panel.isKeyWindow)
        panel.orderOut(nil)
        panel.makeKey()
        precondition(!panel.isKeyWindow)

        let sidebar = CGRect(x: 800, y: 0, width: 280, height: 600)
        func blocks(_ owner: pid_t?, layer: Int? = 0, alpha: Double = 1, frame: CGRect? = nil) -> Bool {
            PanelCoverage.blocks(owner: owner, layer: layer, alpha: alpha,
                                 frame: frame ?? sidebar, sidebar: sidebar, ownPID: 10)
        }
        precondition(!blocks(10))
        precondition(blocks(20))
        precondition(blocks(30))
        precondition(!blocks(30, layer: 3))
        precondition(!blocks(30, alpha: 0))
        precondition(!blocks(30, frame: CGRect(x: 0, y: 0, width: 400, height: 600)))
        precondition(!blocks(nil))
        precondition(!blocks(30, layer: nil))
        precondition(!PanelCoverage.blocks(owner: 30, layer: 0, alpha: 1, frame: nil,
                                          sidebar: sidebar, ownPID: 10))
        precondition(WindowScan.isComplete(expected: [10, 20], matched: [20, 10]))
        precondition(!WindowScan.isComplete(expected: [10, 20], matched: []))
        precondition(!WindowScan.isComplete(expected: [10, 20], matched: [10]))
        precondition(!WindowScan.isComplete(expected: [10, 20], matched: [10, 10]))
        precondition(!WindowScan.isComplete(expected: [10, 20], matched: [10, 30]))
        precondition(WindowScan.isComplete(expected: [], matched: []))
        precondition(WindowScan.isComplete(expected: [10], matched: [10]))
        print("Panel focus, coverage and window scan tests passed")
    }
}
