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
    @Published var count = 0
    @Published var refreshWarning: String?
    private let directory = statusDirectory()
    private let evidenceReader = EvidenceReader()
    private var layout = TabLayout()
    private var windowOrder: [String] = []
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
        for (n, windowId) in windowOrder.enumerated() {
            guard let members = byWindow[windowId] else { continue }
            let rows = members.sorted { ($0.0.tabIndex, $0.0.splitIndex) < ($1.0.tabIndex, $1.0.splitIndex) }.map(\.1)
            var title = "Window \(n + 1) · \(layout.tabCounts[windowId] ?? rows.count) tabs"
            if windowId == layout.frontWindowId { title += " · front" }
            result.append(SessionGroup(id: windowId, title: title, sessions: rows))
        }
        if !unplaced.isEmpty {
            let rows = unplaced.sorted { ($0.rank, $0.title ?? "") < ($1.rank, $1.title ?? "") }
            result.append(SessionGroup(id: "unplaced", title: "Tab not identified yet · click can't jump", sessions: rows))
        }
        return result
    }

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
                    self.count = live.count
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
          repeat with ti from 1 to count of tabs of w
            set t to tab ti of w
            repeat with si from 1 to count of terminals of t
              set s to terminal si of t
              set out to out & (id of s) & sep & wid & sep & ti & sep & si & sep & (name of s) & sep & (working directory of s) & rowSep
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
            guard f.count == 6, let tab = Int(f[2]), let split = Int(f[3]) else { return nil }
            layout.places[f[0]] = TerminalPlace(windowId: f[1], tabIndex: tab, splitIndex: split, title: f[4], cwd: f[5])
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

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ghosttyBundleID
    }

    // Shrinks any Ghostty window overlapping `panel` (Cocoa coordinates) so it sits beside the panel instead of under it.
    static func keepWindowsClear(of panel: NSRect) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: ghosttyBundleID).first else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let clear = CGRect(x: panel.minX, y: primaryHeight - panel.maxY, width: panel.width, height: panel.height)
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for window in windows {
            guard var frame = axFrame(window), frame.intersects(clear) else { continue }
            if frame.midX < clear.midX {
                frame.size.width = clear.minX - frame.minX
            } else {
                frame.size.width = frame.maxX - clear.maxX
                frame.origin.x = clear.maxX
            }
            guard frame.width >= 300 else { continue }
            var origin = frame.origin, size = frame.size
            if let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
                trace("kept clear: window -> \(frame)")
            }
        }
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

    var body: some View {
        Button { Ghostty.focus(session) } label: { SessionRow(session: session) }
            .buttonStyle(.plain)
    }
}

struct SidebarView: View {
    @ObservedObject var store: StatusStore
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Text("Session Status").font(.headline)
                Spacer()
                Text("\(store.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .padding(.top, 6)
            Divider()
            if let warning = store.refreshWarning {
                Text(warning).font(.caption).foregroundStyle(.orange).padding(8)
            }
            if store.groups.isEmpty {
                Spacer()
                Text("No live sessions").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(store.groups) { group in
                            Text(group.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, group.id == store.groups.first?.id ? 0 : 10)
                            ForEach(group.sessions) { SessionButton(session: $0) }
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = StatusStore()
    private var panel: SidebarPanel!
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var keepClearItem: NSMenuItem!
    private var enabled = true
    private var keepClear = UserDefaults.standard.bool(forKey: "keepGhosttyClear")
    private var timer: Timer?
    private var ticks = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        panel.contentView = FirstClickHostingView(rootView: SidebarView(store: store) { [weak self] in self?.setEnabled(false) })
        if !panel.setFrameUsingName("GhosttySidebar"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: screen.maxX - panelWidth, y: screen.minY, width: panelWidth, height: screen.height), display: false)
        }
        panel.setFrameAutosaveName("GhosttySidebar")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Ghostty Sidebar")
        let menu = NSMenu()
        toggleItem = NSMenuItem(title: "Show Sidebar", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = .on
        menu.addItem(toggleItem)
        keepClearItem = NSMenuItem(title: "Keep Ghostty Windows Beside Sidebar", action: #selector(toggleKeepClear), keyEquivalent: "")
        keepClearItem.target = self
        keepClearItem.state = keepClear ? .on : .off
        menu.addItem(keepClearItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        store.refreshLayout()
        timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    @objc private func toggle() { setEnabled(!enabled) }

    @objc private func toggleKeepClear() {
        keepClear.toggle()
        UserDefaults.standard.set(keepClear, forKey: "keepGhosttyClear")
        keepClearItem.state = keepClear ? .on : .off
        if keepClear {
            let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            trace("keep clear on; accessibility trusted: \(AXIsProcessTrustedWithOptions(prompt))")
        }
    }

    private func setEnabled(_ on: Bool) {
        enabled = on
        toggleItem.state = on ? .on : .off
        tick()
    }

    private func tick() {
        ticks += 1
        if ticks % 4 == 0 { store.refreshLayout() }
        let ownAppFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
        let show = enabled && (Ghostty.isFrontmost || ownAppFront)
        if show && !panel.isVisible { panel.orderFront(nil) }
        if !show && !ownAppFront && panel.isVisible { panel.orderOut(nil) }
        if show && keepClear && ticks % 4 == 2 && AXIsProcessTrusted() {
            Ghostty.keepWindowsClear(of: panel.frame)
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
