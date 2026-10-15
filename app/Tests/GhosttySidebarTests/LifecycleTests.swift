import AppKit

@MainActor
final class WindowFixture {
    var element = AXUIElementCreateApplication(getpid())
    var frame: CGRect
    var minimized = false
    var exists = true
    var resizes = 0
    var liveID: CGWindowID = .max
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    init(frame: CGRect) { self.frame = frame }

    func read(_ element: AXUIElement, includingMinimized: Bool) -> Ghostty.Window? {
        guard exists && (!minimized || includingMinimized) else { return nil }
        return Ghostty.Window(element: element, frame: frame, title: "Fixture", fullScreen: false, liveID: liveID)
    }

    func controller() -> SidebarController {
        let controller = SidebarController(store: StatusStore(), autosaveName: nil, onClose: {},
            windowLookup: { self.read($0, includingMinimized: $1) },
            resizeWindow: { _, frame in self.frame = frame; self.resizes += 1; return frame },
            screens: { [self.screen] })
        controller.attach(element)
        return controller
    }

    var inventory: Ghostty.WindowInventory {
        Ghostty.WindowInventory(visible: minimized || !exists ? [] : [read(element, includingMinimized: false)!],
                               elements: exists ? [element] : [])
    }
}

@main
struct LifecycleTests {
    @MainActor
    static func main() {
        let row = ["T1", "W1", "1", "1", "✳ Task", "/repo", "Window"].joined(separator: "\u{1f}") + "\u{1e}"
        for bulk in [Ghostty.ScriptResult.failed, .output(Ghostty.layoutChanged)] {
            var scripts: [String] = []
            let layout = Ghostty.tabLayout { script in
                scripts.append(script)
                return script == Ghostty.tabLayoutScript ? .output(row) : bulk
            }
            precondition(layout?.places["T1"]?.cwd == "/repo" && scripts.last == Ghostty.tabLayoutScript)
        }
        var calls = 0
        precondition(Ghostty.tabLayout { _ in calls += 1; return .timedOut } == nil && calls == 1)
        print("Tab layout fallback tests passed")

        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else {
            print("Controller lifecycle tests skipped: AppKit requires an available display")
            return
        }
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let original = CGRect(x: screen.minX, y: screen.minY,
                              width: min(960, screen.width - 100), height: min(600, screen.height))
        precondition(original.width >= 580)
        let fixture = WindowFixture(frame: original)
        let delegate = AppDelegate()
        let controller = fixture.controller()
        var controllers = delegate.reconcileForTesting(fixture.inventory, controllers: [controller])
        precondition(controllers.count == 1 && controllers[0] === controller)
        precondition(fixture.frame.width == original.width - 280 && fixture.resizes == 1)

        for _ in 0..<3 {
            fixture.minimized = true
            controllers = delegate.reconcileForTesting(fixture.inventory, controllers: controllers)
            precondition(controllers.count == 1 && controllers[0] === controller)
            precondition(fixture.frame.width == original.width - 280 && fixture.resizes == 1)
            fixture.minimized = false
            controllers = delegate.reconcileForTesting(fixture.inventory, controllers: controllers)
            precondition(controllers[0] === controller && fixture.resizes == 1)
        }

        controllers = delegate.reconcileForTesting(Ghostty.WindowInventory(visible: [], elements: [fixture.element]),
                                                   controllers: controllers)
        precondition(controllers[0] === controller && fixture.resizes == 1)
        controllers = delegate.reconcileForTesting(fixture.inventory, controllers: controllers)
        precondition(controllers[0] === controller && fixture.resizes == 1)

        controller.panel.orderFrontRegardless()
        precondition(controller.panel.isVisible)
        controllers = delegate.reconcileForTesting(nil, controllers: controllers)
        precondition(controllers[0] === controller && fixture.resizes == 1)
        precondition(!controller.panel.isVisible)

        fixture.element = AXUIElementCreateApplication(getpid() + 1)
        controllers = delegate.reconcileForTesting(fixture.inventory, controllers: controllers)
        precondition(controllers[0] === controller && CFEqual(controller.window!, fixture.element))
        precondition(fixture.resizes == 1)

        fixture.frame.size.width = original.width + 100
        controllers = delegate.reconcileForTesting(fixture.inventory, controllers: controllers)
        precondition(fixture.frame.width == original.width + 100 - 280 && fixture.resizes == 2)
        fixture.minimized = true
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        precondition(fixture.frame.width == original.width + 100 && fixture.resizes == 3)
        fixture.minimized = false
        let relaunched = fixture.controller()
        controllers = delegate.reconcileForTesting(fixture.inventory, controllers: [relaunched])
        precondition(fixture.frame.width == original.width + 100 - 280 && fixture.resizes == 4)
        fixture.exists = false
        controllers = delegate.reconcileForTesting(fixture.inventory, controllers: controllers)
        precondition(controllers.isEmpty && fixture.resizes == 4)
        controller.panel.orderOut(nil)

        let narrow = WindowFixture(frame: CGRect(x: screen.minX, y: screen.minY, width: 420, height: original.height))
        let widePanel = narrow.controller()
        widePanel.panel.setFrame(CGRect(x: screen.minX, y: screen.minY, width: 600, height: original.height), display: false)
        _ = widePanel.follow(squeeze: true, allowDrop: false, reserveInside: true,
                             observed: narrow.inventory.visible.first)
        precondition(narrow.resizes == 0 && narrow.frame.contains(Screens.flip(widePanel.panel.frame)))
        widePanel.close()

        let first = WindowFixture(frame: original)
        let second = WindowFixture(frame: original)
        second.element = AXUIElementCreateApplication(getpid() + 2)
        second.liveID = .max - 1
        let firstController = first.controller()
        let secondController = second.controller()
        let overlapping = AppDelegate()
        let both = Ghostty.WindowInventory(visible: first.inventory.visible + second.inventory.visible,
                                          elements: [first.element, second.element])
        var pair = overlapping.reconcileForTesting(both, controllers: [firstController, secondController])
        precondition(pair.count == 2 && first.resizes == 1 && second.resizes == 1)
        first.minimized = true
        pair = overlapping.reconcileForTesting(Ghostty.WindowInventory(visible: second.inventory.visible,
                                              elements: [first.element, second.element]), controllers: pair)
        precondition(pair.count == 2)
        precondition(CFEqual(firstController.window!, first.element))
        precondition(CFEqual(secondController.window!, second.element))
        precondition(first.resizes == 1 && second.resizes == 1)
        first.minimized = false
        pair = overlapping.reconcileForTesting(Ghostty.WindowInventory(visible: first.inventory.visible + second.inventory.visible,
                                              elements: [first.element, second.element]), controllers: pair)
        precondition(pair.count == 2 && first.resizes == 1 && second.resizes == 1)
        first.exists = false
        pair = overlapping.reconcileForTesting(second.inventory, controllers: pair)
        precondition(pair.count == 1 && pair[0] === secondController && second.resizes == 1)
        secondController.close()
        print("Controller lifecycle tests passed")
    }
}
