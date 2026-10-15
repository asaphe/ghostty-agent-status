import Foundation
import Darwin

@main
struct DiagnosticsTests {
    static func main() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        setenv("GHOSTTY_AGENT_STATUS_DIR", temporary.path, 1)
        setenv("GHOSTTY_AGENT_STATUS_DIAGNOSTICS", "0", 1)
        Diagnostics.emit("test.disabled")
        precondition(!FileManager.default.fileExists(atPath: Diagnostics.directory.path))
        setenv("GHOSTTY_AGENT_STATUS_DIAGNOSTICS", "1", 1)
        let secret = "private command /Users/private answer"
        Diagnostics.emit("sidebar.reconcile", agent: "claude", fields: ["session_id": "session-1",
            "terminal_id": "terminal-1", "state": "waiting", "hook_state": "working", "evidence_ms": 123.5,
            "reason": "newer_evidence", "command": secret, "title": secret, "message": secret])
        let log = Diagnostics.directory.appendingPathComponent("sidebar.jsonl")
        let data = try Data(contentsOf: log)
        let row = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(row["agent"] as? String == "claude")
        precondition(row["session_id"] as? String == Diagnostics.fingerprint("session-1"))
        precondition(row["state"] as? String == "waiting")
        precondition(!String(data: data, encoding: .utf8)!.contains(secret))
        let permissions = try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        try Data(repeating: 32, count: Diagnostics.limit).write(to: log)
        Diagnostics.emit("test.rotate")
        precondition(FileManager.default.fileExists(atPath: log.path + ".1"))
        let rotated = try Data(contentsOf: log)
        precondition(rotated.count < Diagnostics.limit)
        try FileManager.default.removeItem(at: log)
        let target = temporary.appendingPathComponent("untouched")
        try Data("original".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: target)
        Diagnostics.emit("test.symlink")
        let untouched = try String(contentsOf: target, encoding: .utf8)
        precondition(untouched == "original")
        precondition(Diagnostics.fingerprint("session-1") == "84097828fc31a8c8")
        print("Diagnostic privacy, identity, opt-in, rotation and symlink tests passed")
    }
}
