import Foundation

struct SessionStatus: Codable, Identifiable, Equatable {
    var agent: String
    var sessionId: String
    var state: String
    var title: String?
    var cwd: String?
    var repo: String?
    var branch: String?
    var color: String?
    var ghosttyTerminalId: String?
    var pid: Int32?
    var updatedAt: String?
    var message: String?

    var id: String { "\(agent)-\(sessionId)" }

    var rank: Int {
        switch state {
        case "waiting": return 0
        case "working": return 1
        case "idle": return 2
        default: return 3
        }
    }
}

func statusDirectory() -> URL {
    if let base = ProcessInfo.processInfo.environment["GHOSTTY_AGENT_STATUS_DIR"], !base.isEmpty {
        return URL(fileURLWithPath: base).appendingPathComponent("status")
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/ghostty-agent-status/status")
}

func processAlive(_ pid: Int32) -> Bool {
    pid > 1 && (kill(pid, 0) == 0 || errno == EPERM)
}

struct TerminalPlace: Equatable {
    let windowId: String
    let tabIndex: Int
    let splitIndex: Int
    var title: String = ""
    var cwd: String = ""
}

struct TabLayout: Equatable {
    var places: [String: TerminalPlace] = [:]
    var frontWindowId: String?
    var tabCounts: [String: Int] = [:]

    func preservingTitles(from previous: TabLayout) -> TabLayout {
        var result = self
        for (id, place) in places where place.title.hasPrefix("tty-probe-") {
            if let title = previous.places[id]?.title, !title.hasPrefix("tty-probe-") {
                result.places[id]?.title = title
            }
        }
        return result
    }
}

struct SessionGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let sessions: [SessionStatus]
}
