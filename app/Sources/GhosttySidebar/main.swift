import AppKit
import SwiftUI

let ghosttyBundleID = "com.mitchellh.ghostty"
let panelWidth: CGFloat = 280
let traceURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/GhosttySidebar.log")

func trace(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: traceURL) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: traceURL)
    }
}

@MainActor
final class StatusStore: ObservableObject {
    @Published var groups: [SessionGroup] = []
    @Published var refreshWarning: String?
    @Published var accessibilityWarning: String?
    private let directory = statusDirectory()
    private let evidenceReader = EvidenceReader()
    private var layout = TabLayout()
    private var windowOrder: [String] = []
    private var unplacedSince: [String: Date] = [:]
    private var layoutInFlight = false

    private func group(_ sessions: [SessionStatus]) -> [SessionGroup] {
        var byWindow: [String: [(TerminalPlace, SessionStatus)]] = [:]
        var unplaced: [SessionStatus] = []
        for s in sessions {
            if let id = s.ghosttyTerminalId, let place = layout.places[id] {
                byWindow[place.windowId, default: []].append((place, s))
            } else {
                unplaced.append(s)
            }
        }
        var result: [SessionGroup] = []
        for windowId in windowOrder {
            guard let members = byWindow[windowId] else { continue }
            let rows = members.sorted { ($0.0.tabIndex, $0.0.splitIndex) < ($1.0.tabIndex, $1.0.splitIndex) }.map(\.1)
            result.append(SessionGroup(id: windowId, title: "", sessions: rows))
        }
        let now = Date()
        unplacedSince = unplacedSince.filter { id, _ in unplaced.contains { $0.id == id } }
        if !unplaced.isEmpty {
            let rows = unplaced.sorted { ($0.rank, $0.title ?? "") < ($1.rank, $1.title ?? "") }
            var notes: [String: String] = [:]
            for s in rows {
                let since = unplacedSince[s.id] ?? now
                unplacedSince[s.id] = since
                notes[s.id] = now.timeIntervalSince(since) < 10 ? "Finding its tab…" : "Tab not found · click can't jump"
            }
            result.append(SessionGroup(id: "unplaced", title: "Tab unknown", sessions: rows, notes: notes))
        }
        return result
    }

    func windowId(titled title: String) -> String? { layout.windowId(titled: title) }

    func refreshLayout() {
        guard !layoutInFlight else { return }
        layoutInFlight = true
        let previous = layout
        let directory = directory
        let reader = evidenceReader
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: ghosttyBundleID).isEmpty
        DispatchQueue.global(qos: .utility).async {
            let fresh = running ? Ghostty.tabLayout()?.preservingTitles(from: previous) : TabLayout()
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let records = (urls ?? []).filter { $0.pathExtension == "json" }.compactMap {
                try? decoder.decode(SessionStatus.self, from: Data(contentsOf: $0))
            }
            reader.refreshIndex()
            let live = Reconcile.sessions(records, layout: fresh ?? previous, names: reader.codexNames,
                                          evidence: { reader.evidence(agent: $0, id: $1) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.layoutInFlight = false
                    self.refreshWarning = fresh == nil ? "Ghostty refresh failed · retrying" :
                        (urls == nil ? "Status files unavailable · using session activity" : nil)
                    if let fresh { self.layout = fresh }
                    let open = Set(self.layout.tabCounts.keys)
                    self.windowOrder.removeAll { !open.contains($0) }
                    for windowId in open.sorted() where !self.windowOrder.contains(windowId) {
                        self.windowOrder.append(windowId)
                    }
                    let groups = self.group(live)
                    if groups != self.groups { self.groups = groups }
                }
            }
        }
    }

}

enum Ghostty {
    static let tabLayoutScript = """
    set out to ""
    set sep to character id 31
    set rowSep to character id 30
    with timeout of 8 seconds
      tell application "Ghostty"
        repeat with wi from 1 to count of windows
          set w to window wi
          set wid to id of w
          set wname to name of w
          repeat with ti from 1 to count of tabs of w
            set t to tab ti of w
            repeat with si from 1 to count of terminals of t
              set s to terminal si of t
              set out to out & (id of s) & sep & wid & sep & ti & sep & si & sep & (name of s) & sep & (working directory of s) & sep & wname & rowSep
            end repeat
          end repeat
        end repeat
      end tell
    end timeout
    return out
    """

    static func tabLayout() -> TabLayout? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", tabLayoutScript]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: watchdog)
        defer { watchdog.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        var layout = TabLayout()
        var tabs: [String: Set<Int>] = [:]
        for line in text.components(separatedBy: "\u{1e}") where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let f = line.components(separatedBy: "\u{1f}")
            guard f.count == 7, let tab = Int(f[2]), let split = Int(f[3]) else { return nil }
            layout.places[f[0]] = TerminalPlace(windowId: f[1], tabIndex: tab, splitIndex: split, title: f[4], cwd: f[5])
            layout.windowNames[f[1]] = f[6]
            if layout.frontWindowId == nil { layout.frontWindowId = f[1] }
            tabs[f[1], default: []].insert(tab)
        }
        layout.tabCounts = tabs.mapValues(\.count)
        return layout
    }

    static func focus(_ session: SessionStatus) {
        guard let id = session.ghosttyTerminalId, !id.contains("\""), !id.contains("\\") else {
            NSRunningApplication.runningApplications(withBundleIdentifier: ghosttyBundleID).first?.activate()
            return
        }
        trace("ghostty focus: \(id)")
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Ghostty\" to focus (terminal id \"\(id)\")")?.executeAndReturnError(&error)
        if let error {
            trace("ghostty focus failed: \(error)")
            NSRunningApplication.runningApplications(withBundleIdentifier: ghosttyBundleID).first?.activate()
        }
    }

    // The window server reports a window's frame live during a drag; Accessibility only catches up afterwards.
    static func onScreenWindows() -> [(id: CGWindowID, frame: CGRect)] {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: ghosttyBundleID).first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid, info[kCGWindowLayer as String] as? Int == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID, let frame = cgFrame(info) else { return nil }
            return (id, frame)
        }
    }

    static func liveFrame(_ id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]], let info = list.first,
              info[kCGWindowIsOnscreen as String] as? Bool == true else { return nil }
        return cgFrame(info)
    }

    // Whether another app's window, or another Ghostty window, stacked above `id` overlaps `rect`.
    static func covered(above id: CGWindowID, _ rect: CGRect) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], id) as? [[String: Any]]
        else { return false }
        let own = getpid()
        return list.contains { info in
            info[kCGWindowOwnerPID as String] as? pid_t != own && info[kCGWindowLayer as String] as? Int == 0
                && (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 && cgFrame(info)?.intersects(rect) == true
        }
    }

    private static func cgFrame(_ info: [String: Any]) -> CGRect? {
        guard let bounds = info[kCGWindowBounds as String] else { return nil }
        return CGRect(dictionaryRepresentation: bounds as! CFDictionary)
    }

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ghosttyBundleID
    }

    struct Window {
        let element: AXUIElement
        let frame: CGRect
        let title: String
        let fullScreen: Bool
    }

    // Front-to-back. Hidden native tabs share their group's frame, so only the frontmost window per frame is kept.
    static func windows() -> [Window] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: ghosttyBundleID).first else { return [] }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        guard let elements = attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        var result: [Window] = []
        for element in elements {
            guard attribute(element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole as String,
                  attribute(element, kAXMinimizedAttribute) as? Bool != true,
                  let frame = axFrame(element), !result.contains(where: { $0.frame == frame }) else { continue }
            result.append(Window(element: element, frame: frame, title: attribute(element, kAXTitleAttribute) as? String ?? "",
                                 fullScreen: attribute(element, "AXFullScreen") as? Bool == true))
        }
        return result
    }

    static func window(_ element: AXUIElement) -> Window? {
        guard attribute(element, kAXMinimizedAttribute) as? Bool != true, let frame = axFrame(element) else { return nil }
        return Window(element: element, frame: frame, title: attribute(element, kAXTitleAttribute) as? String ?? "",
                      fullScreen: attribute(element, "AXFullScreen") as? Bool == true)
    }

    // Returns the frame Ghostty actually took, which can differ from the one asked for.
    @discardableResult
    static func setFrame(_ element: AXUIElement, _ frame: CGRect) -> CGRect? {
        var origin = frame.origin, size = frame.size
        if let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pos)
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sz)
        }
        return axFrame(element)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func axFrame(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }
}

extension Color {
    init?(hex: String?) {
        guard var s = hex else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

struct StateBadge: View {
    let state: String

    var tint: Color {
        switch state {
        case "waiting": return .orange
        case "working": return .green
        case "idle": return .gray
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(state).font(.caption2.weight(.semibold)).foregroundStyle(tint)
        }
    }
}

struct SessionRow: View {
    let session: SessionStatus
    var note: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: session.color) ?? .gray)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    StateBadge(state: session.state)
                    Spacer()
                    Text(session.agent).font(.caption2).foregroundStyle(.secondary)
                }
                Text(session.title ?? session.sessionId).font(.callout.weight(.medium)).lineLimit(2)
                if let repo = session.repo {
                    Text([repo, session.branch].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                if let message = session.message, !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.orange).lineLimit(3)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
        .help([session.cwd, session.updatedAt.map { "Last event: \($0)" }].compactMap { $0 }.joined(separator: "\n"))
    }
}

struct SessionButton: View {
    let session: SessionStatus
    var note: String?

    var body: some View {
        Button { Ghostty.focus(session) } label: { SessionRow(session: session, note: note) }
            .buttonStyle(.plain)
    }
}

final class PanelFilter: ObservableObject {
    enum Scope: Equatable { case all, pending, window(String) }
    @Published var scope: Scope = .all
    @Published var showsUnplaced = true
    var misses = 0

    func set(_ scope: Scope) { if self.scope != scope { self.scope = scope } }
}

struct SidebarView: View {
    @ObservedObject var store: StatusStore
    @ObservedObject var filter: PanelFilter
    let onClose: () -> Void

    var groups: [SessionGroup] {
        switch filter.scope {
        case .all: return store.groups
        case .pending: return []
        case .window(let id): return store.groups.filter { $0.id == id || ($0.id == "unplaced" && filter.showsUnplaced) }
        }
    }

    var emptyText: String {
        switch filter.scope {
        case .all: return "No live sessions"
        case .pending: return "Matching this window…"
        case .window: return "No agent sessions in this window"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Text("Session Status").font(.headline)
                Spacer()
                Text("\(groups.reduce(0) { $0 + $1.sessions.count })").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ForEach([store.accessibilityWarning, store.refreshWarning].compactMap { $0 }, id: \.self) { warning in
                Text(warning).font(.caption).foregroundStyle(.orange).padding(8)
            }
            if groups.isEmpty {
                Spacer()
                Text(emptyText).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(groups) { group in
                            if group.id != groups.first?.id { Divider().padding(.vertical, 4) }
                            if !group.title.isEmpty {
                                Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            ForEach(group.sessions) { SessionButton(session: $0, note: group.notes[$0.id]) }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

final class SidebarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// A non-activating panel otherwise swallows the first click as "focus the window" and never delivers it.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum Screens {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    // Cocoa and Accessibility differ only in where y starts, so the same flip converts both ways.
    static func flip(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static var visibleFrames: [CGRect] { NSScreen.screens.map { flip($0.visibleFrame) } }
}

@MainActor
final class SidebarController {
    let panel: SidebarPanel
    let filter = PanelFilter()
    private(set) var window: AXUIElement?
    private(set) var windowFrame: CGRect?
    private var squeezed: (originalWidth: CGFloat, appliedWidth: CGFloat)?
    private var requested: (target: CGRect, took: CGRect)?
    private var placed: NSRect?
    private var dragging = false
    private var liveWindowID: CGWindowID?

    init(store: StatusStore, autosaveName: String?, onClose: @escaping () -> Void) {
        panel = SidebarPanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 600),
                             styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                             backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 200, height: 200)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = FirstClickHostingView(rootView: SidebarView(store: store, filter: filter, onClose: onClose))
        guard let autosaveName else { return }
        if !panel.setFrameUsingName(autosaveName), let screen = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: screen.maxX - panelWidth, y: screen.minY, width: panelWidth, height: screen.height), display: false)
        }
        panel.setFrameAutosaveName(autosaveName)
    }

    func attach(_ element: AXUIElement?) {
        if let window, let element, CFEqual(window, element) { return }
        release()
        window = element
        windowFrame = element.flatMap { Ghostty.window($0)?.frame }
        liveWindowID = nil
        placed = nil
    }

    // A native tab switch can hand the same on-screen window a new element; keep the squeeze bookkeeping.
    func adopt(_ element: AXUIElement) {
        window = element
    }

    // Gives the window back the width it had before the sidebar squeezed it, unless someone resized it since.
    func release() {
        if let window, let squeezed, var frame = Ghostty.window(window)?.frame, frame.width == squeezed.appliedWidth {
            frame.size.width = squeezed.originalWidth
            Ghostty.setFrame(window, frame)
            trace("released window -> \(frame)")
        }
        squeezed = nil
        requested = nil
    }

    func close() {
        release()
        panel.orderOut(nil)
    }

    // Untrusted fallback: no window to follow, so dock to the nearer edge of the panel's screen.
    func dockToScreen() {
        guard NSEvent.pressedMouseButtons == 0, let screen = panel.screen?.visibleFrame else { return }
        var frame = panel.frame
        frame.origin.y = screen.minY
        frame.size.height = screen.height
        frame.origin.x = frame.midX < screen.midX ? screen.minX : screen.maxX - frame.width
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    // Returns the followed window, or nil once it is gone.
    func follow(squeeze: Bool, allowDrop: Bool) -> Ghostty.Window? {
        let mouseDown = NSEvent.pressedMouseButtons != 0
        if let placed, panel.frame != placed, mouseDown { dragging = true }
        if dragging {
            if mouseDown { return window.flatMap(Ghostty.window) }
            dragging = false
            placed = nil
            if allowDrop {
                let candidates = Ghostty.windows()
                if let i = Placement.dropTarget(panel: Screens.flip(panel.frame), windows: candidates.map(\.frame)) {
                    attach(candidates[i].element)
                    trace("attached by drop: \(candidates[i].title)")
                }
            }
        }
        guard let element = window, let current = Ghostty.window(element) else { return nil }
        guard let screen = Placement.screen(for: current.frame, among: Screens.visibleFrames) else { return current }
        let width = panel.frame.width
        let place = Placement.place(window: current.frame, fullScreen: current.fullScreen, screen: screen, width: width, squeeze: squeeze)
        var frame = current.frame
        if !squeeze, squeezed != nil {
            release()
            frame = Ghostty.window(element)?.frame ?? frame
        } else if let target = place.window, target != frame, requested.map({ $0 != (target, frame) }) ?? true,
                  let took = Ghostty.setFrame(element, target) {
            requested = (target, took)
            let original = squeezed.map { $0.appliedWidth == frame.width ? $0.originalWidth : frame.width } ?? frame.width
            squeezed = (originalWidth: original, appliedWidth: took.width)
            trace("squeezed window -> \(took)")
            frame = took
        }
        var rect = place.panel
        if squeezed?.appliedWidth == frame.width { rect.origin.x = min(frame.maxX, screen.maxX - width) }
        windowFrame = frame
        if liveWindowID.flatMap(Ghostty.liveFrame) != frame {
            liveWindowID = Ghostty.onScreenWindows().first { $0.frame == frame }?.id
        }
        let target = Screens.flip(rect)
        if panel.frame != target { panel.setFrame(target, display: true) }
        placed = panel.frame
        return current
    }

    // Shown only while nothing stacked above its Ghostty window covers the spot, so each display behaves on its own.
    func updateVisibility(enabled: Bool) {
        let rect = Screens.flip(panel.frame)
        let show = enabled && !dragging && liveWindowID.map { Ghostty.liveFrame($0) != nil && !Ghostty.covered(above: $0, rect) } ?? false
        guard show || dragging else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        if !panel.isVisible || Ghostty.covered(above: CGWindowID(panel.windowNumber), rect) { panel.orderFront(nil) }
    }

    // Mid-drag fast path: moves only the panel, from the window server's live frame; `follow` does the rest on release.
    func track() {
        if let placed, panel.frame != placed { dragging = true }
        guard !dragging, let id = liveWindowID, let frame = Ghostty.liveFrame(id), frame != windowFrame,
              let screen = Placement.screen(for: frame, among: Screens.visibleFrames) else { return }
        let width = panel.frame.width
        var rect = Placement.place(window: frame, fullScreen: false, screen: screen, width: width, squeeze: false).panel
        if squeezed?.appliedWidth == frame.width { rect.origin.x = min(frame.maxX, screen.maxX - width) }
        windowFrame = frame
        panel.setFrame(Screens.flip(rect), display: true)
        placed = panel.frame
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = StatusStore()
    private var controllers: [SidebarController] = []
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var attachItem: NSMenuItem!
    private var perWindowItem: NSMenuItem!
    private var keepClearItem: NSMenuItem!
    private var enabled = true
    private var keepClear = UserDefaults.standard.bool(forKey: "keepGhosttyClear")
    private var perWindow = UserDefaults.standard.bool(forKey: "sidebarPerWindow")
    private var timer: Timer?
    private var dragTimer: Timer?
    private var trusted = false
    private var ticks = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Ghostty Sidebar")
        let menu = NSMenu()
        toggleItem = item(menu, "Show Sidebar", #selector(toggle), on: true)
        attachItem = item(menu, "Attach to Front Window", #selector(attachToFront), on: false)
        perWindowItem = item(menu, "One Sidebar per Window", #selector(togglePerWindow), on: perWindow)
        keepClearItem = item(menu, "Keep Ghostty Windows Beside Sidebar", #selector(toggleKeepClear), on: keepClear)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        attachItem.isHidden = perWindow
        if !perWindow { controllers = [makeController(autosaveName: "GhosttySidebar")] }

        store.refreshLayout()
        timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        dragTimer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.enabled, self.trusted, NSEvent.pressedMouseButtons != 0 else { return }
                self.controllers.forEach { $0.track() }
            }
        }
        if let dragTimer { RunLoop.main.add(dragTimer, forMode: .common) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controllers.forEach { $0.release() }
    }

    private func item(_ menu: NSMenu, _ title: String, _ action: Selector, on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        menu.addItem(item)
        return item
    }

    private func makeController(autosaveName: String?) -> SidebarController {
        SidebarController(store: store, autosaveName: autosaveName) { [weak self] in self?.setEnabled(false) }
    }

    @discardableResult
    private func requestTrust(_ reason: String) -> Bool {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(prompt)
        trace("\(reason); accessibility trusted: \(trusted)")
        return trusted
    }

    @objc private func toggle() { setEnabled(!enabled) }

    @objc private func attachToFront() {
        guard requestTrust("attach to front window"), let single = controllers.first, !perWindow else { return }
        single.attach(Ghostty.windows().first?.element)
    }

    @objc private func togglePerWindow() {
        perWindow.toggle()
        UserDefaults.standard.set(perWindow, forKey: "sidebarPerWindow")
        perWindowItem.state = perWindow ? .on : .off
        attachItem.isHidden = perWindow
        controllers.forEach { $0.close() }
        controllers = perWindow ? [] : [makeController(autosaveName: "GhosttySidebar")]
        if perWindow { requestTrust("per-window sidebars on") } else { controllers.first?.attach(busiestWindow()) }
    }

    @objc private func toggleKeepClear() {
        keepClear.toggle()
        UserDefaults.standard.set(keepClear, forKey: "keepGhosttyClear")
        keepClearItem.state = keepClear ? .on : .off
        if keepClear { requestTrust("keep clear on") }
    }

    private func setEnabled(_ on: Bool) {
        enabled = on
        toggleItem.state = on ? .on : .off
        if !on { controllers.forEach { $0.release() } }
        tick()
    }

    private func tick() {
        ticks += 1
        if ticks % 4 == 0 { store.refreshLayout() }
        trusted = AXIsProcessTrusted()
        let warning = trusted ? nil : "Can't attach to Ghostty windows: no Accessibility access. In System Settings → Privacy & Security → Accessibility, remove Ghostty Sidebar with − if listed, then choose Attach to Front Window in the menu-bar menu."
        if store.accessibilityWarning != warning {
            store.accessibilityWarning = warning
            trace("accessibility trusted: \(trusted)")
        }
        if perWindow && !trusted && controllers.isEmpty { controllers = [makeController(autosaveName: "GhosttySidebar")] }
        guard trusted else {
            let ownAppFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
            let show = enabled && (Ghostty.isFrontmost || ownAppFront)
            for c in controllers {
                c.panel.level = .floating
                if show { c.dockToScreen() }
                if show && !c.panel.isVisible { c.panel.orderFront(nil) }
                if !show && !ownAppFront && c.panel.isVisible { c.panel.orderOut(nil) }
            }
            return
        }
        if enabled {
            if perWindow { syncPerWindow() } else if let single = controllers.first { followSingle(single) }
        }
        for c in controllers {
            c.panel.level = .normal
            c.updateVisibility(enabled: enabled)
        }
    }

    // The window with the most live sessions; ties go to the frontmost.
    private func busiestWindow() -> AXUIElement? {
        let counts = Dictionary(store.groups.map { ($0.id, $0.sessions.count) }, uniquingKeysWith: +)
        let windows = Ghostty.windows()
        let scores = windows.map { w in store.windowId(titled: w.title).flatMap { counts[$0] } ?? 0 }
        guard let best = scores.indices.max(by: { (scores[$0], -$0) < (scores[$1], -$1) }) else { return nil }
        return windows[best].element
    }

    private func followSingle(_ single: SidebarController) {
        single.filter.set(.all)
        if !single.filter.showsUnplaced { single.filter.showsUnplaced = true }
        if single.window == nil {
            let candidates = Ghostty.windows()
            let i = Placement.dropTarget(panel: Screens.flip(single.panel.frame), windows: candidates.map(\.frame)) ?? 0
            guard i < candidates.count else { return }
            single.attach(candidates[i].element)
        }
        if single.follow(squeeze: keepClear, allowDrop: true) == nil {
            single.attach(busiestWindow())
            trace("attached window closed; moved to busiest window")
        }
    }

    private func syncPerWindow() {
        let windows = Ghostty.windows()
        var unclaimed = windows
        controllers.removeAll { c in
            let match = unclaimed.firstIndex { w in c.window.map { CFEqual($0, w.element) } == true }
                ?? unclaimed.firstIndex { $0.frame == c.windowFrame }
            guard let match else { c.close(); return true }
            c.adopt(unclaimed.remove(at: match).element)
            return false
        }
        for w in unclaimed {
            let c = makeController(autosaveName: nil)
            c.filter.set(.pending)
            c.attach(w.element)
            controllers.append(c)
        }
        let front = windows.first?.element
        for c in controllers {
            let isFront = c.window.map { w in front.map { CFEqual(w, $0) } ?? false } ?? false
            if c.filter.showsUnplaced != isFront { c.filter.showsUnplaced = isFront }
            guard let current = c.follow(squeeze: keepClear, allowDrop: false) else { continue }
            if let id = store.windowId(titled: current.title) {
                c.filter.set(.window(id))
                c.filter.misses = 0
            } else if c.filter.scope == .pending {
                c.filter.misses += 1
                if c.filter.misses >= 8 { c.filter.set(.all) }
            }
        }
    }
}

if CommandLine.arguments.contains("--snapshot") {
    guard let layout = Ghostty.tabLayout() else {
        fputs("Ghostty lookup failed\n", stderr)
        exit(1)
    }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let urls = (try? FileManager.default.contentsOfDirectory(at: statusDirectory(), includingPropertiesForKeys: nil)) ?? []
    let records = urls.filter { $0.pathExtension == "json" }.compactMap {
        try? decoder.decode(SessionStatus.self, from: Data(contentsOf: $0))
    }
    let reader = EvidenceReader()
    reader.refreshIndex()
    let rows = Reconcile.sessions(records, layout: layout, names: reader.codexNames,
                                  evidence: { reader.evidence(agent: $0, id: $1) })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    print(String(data: try encoder.encode(rows.sorted { $0.id < $1.id }), encoding: .utf8)!)
} else {
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

}
