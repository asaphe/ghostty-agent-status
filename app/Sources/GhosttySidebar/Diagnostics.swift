import Foundation
import CryptoKit
import Darwin

enum Diagnostics {
    static let limit = 2 * 1024 * 1024
    static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["GHOSTTY_AGENT_STATUS_DIAGNOSTICS_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return statusDirectory().deletingLastPathComponent().appendingPathComponent("diagnostics")
    }
    static var enabled: Bool {
        if let value = ProcessInfo.processInfo.environment["GHOSTTY_AGENT_STATUS_DIAGNOSTICS"] { return value == "1" }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("enabled").path)
    }
    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
    private static let sourceID: String = {
        guard let url = Bundle.main.executableURL, let data = try? Data(contentsOf: url) else { return "unavailable" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }()
    static func clean(_ fields: [String: Any]) -> [String: Any] {
        let numbers: Set<String> = ["elapsed_ms", "record_count", "row_count", "evidence_ms", "reported_ms", "returncode"]
        let states: Set<String> = ["working", "waiting", "idle", "done", "background", "unknown"]
        var result: [String: Any] = [:]
        for (key, value) in fields {
            if ["session_id", "terminal_id"].contains(key), let text = value as? String {
                result[key] = fingerprint(text)
            } else if numbers.contains(key), let number = value as? NSNumber, number.doubleValue.isFinite {
                result[key] = number
            } else if ["state", "hook_state", "evidence_state"].contains(key), let state = value as? String, states.contains(state) {
                result[key] = state
            } else if ["reason", "event_type"].contains(key), let text = value as? String,
                      text.range(of: "^[a-zA-Z0-9_]{1,64}$", options: .regularExpression) != nil {
                result[key] = text
            } else if key == "changed", let changed = value as? Bool {
                result[key] = changed
            }
        }
        return result
    }
    static func emit(_ stage: String, agent: String? = nil, fields: [String: Any] = [:]) {
        guard enabled else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let lock = open(directory.appendingPathComponent("sidebar.lock").path, O_WRONLY | O_CREAT | O_NOFOLLOW, 0o600)
            guard lock >= 0 else { return }
            defer { close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
            defer { flock(lock, LOCK_UN) }
            let path = directory.appendingPathComponent("sidebar.jsonl")
            if let size = (try? fm.attributesOfItem(atPath: path.path)[.size]) as? Int, size >= limit {
                let backup = directory.appendingPathComponent("sidebar.jsonl.1")
                guard rename(path.path, backup.path) == 0 else { return }
            }
            var row = clean(fields)
            row.merge(["schema": 1, "timestamp_ms": Date().timeIntervalSince1970 * 1000,
                       "pid": getpid(), "producer": "sidebar", "source_id": sourceID, "stage": stage,
                       "reader_mode": CommandLine.arguments.contains("--observe-status") ? "headless" : "app"]) { _, new in new }
            if let agent, ["claude", "codex", "terminal"].contains(agent) { row["agent"] = agent }
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            data.append(10)
            let fd = open(path.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { return }
            defer { close(fd) }
            fchmod(fd, 0o600)
            data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let count = write(fd, base.advanced(by: offset), buffer.count - offset)
                    guard count > 0 else { return }
                    offset += count
                }
            }
        } catch { }
    }
}
