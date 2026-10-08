import CoreGraphics

// All rects are in Accessibility coordinates: origin at the top-left of the primary screen, y growing down.
struct PanelPlacement: Equatable {
    var panel: CGRect
    var window: CGRect?
}

enum Placement {
    static let minimumWindowWidth: CGFloat = 300

    static func place(window: CGRect, fullScreen: Bool, screen: CGRect, width: CGFloat, squeeze: Bool) -> PanelPlacement {
        if fullScreen {
            return PanelPlacement(panel: CGRect(x: window.maxX - width, y: window.minY, width: width, height: window.height))
        }
        let top = max(window.minY, screen.minY)
        let height = max(min(window.maxY, screen.maxY) - top, 200)
        func panel(at x: CGFloat) -> CGRect { CGRect(x: x, y: top, width: width, height: height) }
        if window.maxX + width <= screen.maxX {
            return PanelPlacement(panel: panel(at: window.maxX))
        }
        if squeeze {
            var squeezed = window
            squeezed.size.width = screen.maxX - width - window.minX
            if squeezed.width >= minimumWindowWidth {
                return PanelPlacement(panel: panel(at: squeezed.maxX), window: squeezed)
            }
        }
        return PanelPlacement(panel: panel(at: min(window.maxX, screen.maxX) - width))
    }

    static func screen(for rect: CGRect, among screens: [CGRect]) -> CGRect? {
        screens.max { area($0.intersection(rect)) < area($1.intersection(rect)) }.flatMap { area($0.intersection(rect)) > 0 ? $0 : nil }
    }

    // The window a dropped panel lands on: the largest overlap, counting a panel dropped just beside a window.
    static func dropTarget(panel: CGRect, windows: [CGRect], slop: CGFloat = 40) -> Int? {
        let reach = panel.insetBy(dx: -slop, dy: 0)
        let overlaps = windows.map { area($0.intersection(reach)) }
        guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 else { return nil }
        return best
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
}
