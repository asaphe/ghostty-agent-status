import Foundation

private let fractionalTimestamps: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions.insert(.withFractionalSeconds)
    return formatter
}()
private let wholeSecondTimestamps = ISO8601DateFormatter()

func timestamp(_ value: String?) -> Date? {
    guard let value else { return nil }
    return fractionalTimestamps.date(from: value) ?? wholeSecondTimestamps.date(from: value)
}

struct Evidence: Equatable {
    let state: String
    let date: Date
    var clearsWaiting = false
}

enum SessionEvidence {
    static func parse(_ row: [String: Any], agent: String) -> Evidence? {
        guard let date = timestamp(row["timestamp"] as? String) else { return nil }
        let type = row["type"] as? String
        if agent == "claude" {
            guard row["isSidechain"] as? Bool != true else { return nil }
            // Deny, Esc and a declined plan fire no hook; the transcript's interrupt row and turn_duration end the turn.
            if type == "system" { return row["subtype"] as? String == "turn_duration" ? Evidence(state: "idle", date: date) : nil }
            guard let message = row["message"] as? [String: Any] else { return nil }
            if type == "user" {
                let blocks = message["content"] as? [[String: Any]] ?? []
                let interrupted = blocks.contains { ($0["text"] as? String)?.hasPrefix("[Request interrupted by user") == true }
                return Evidence(state: interrupted ? "idle" : "working", date: date)
            }
            guard type == "assistant" else { return nil }
            if message["stop_reason"] as? String == "end_turn" { return Evidence(state: "idle", date: date) }
            let blocks = message["content"] as? [[String: Any]] ?? []
            if blocks.contains(where: { $0["type"] as? String == "tool_use" && $0["name"] as? String == "AskUserQuestion" }) {
                return Evidence(state: "waiting", date: date)
            }
            return Evidence(state: "working", date: date)
        }
        guard let payload = row["payload"] as? [String: Any] else { return nil }
        let event = payload["type"] as? String ?? ""
        if type == "event_msg" {
            if ["task_complete", "turn_aborted"].contains(event) { return Evidence(state: "idle", date: date) }
            if ["task_started", "user_message"].contains(event) { return Evidence(state: "working", date: date) }
        }
        if type == "response_item" {
            if event == "message", payload["role"] as? String == "assistant", payload["phase"] as? String == "final_answer" {
                return Evidence(state: "idle", date: date)
            }
            if event == "message", payload["role"] as? String == "user" {
                return Evidence(state: "working", date: date)
            }
            if ["function_call", "custom_tool_call"].contains(event) {
                let name = payload["name"] as? String ?? ""
                return Evidence(state: ["request_user_input", "request_user_input_async"].contains(shortTool(name)) ? "waiting" : "working", date: date)
            }
            if ["function_call_output", "custom_tool_call_output"].contains(event) { return Evidence(state: "working", date: date) }
        }
        return nil
    }

    static func shortTool(_ name: String) -> String {
        (name.components(separatedBy: ".").last ?? name).components(separatedBy: "__").last ?? name
    }

    // Context Codex itself writes as user-role rows, observed in recorded transcripts: it answers no question.
    static let injectedPrefixes = ["# AGENTS.md instructions", "<environment_context>", "<guardian_tool_descriptions>",
                                   "<node_repl_review_evidence>", "<recommended_plugins>", "<skill>", "<turn_aborted>",
                                   "<user_action>"]

    static func typedPrompt(_ blocks: [String]) -> String? {
        let texts = blocks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let injected = !texts.isEmpty && texts.allSatisfy { text in injectedPrefixes.contains(where: text.hasPrefix) }
        return injected ? nil : blocks.joined()
    }

    static func questionReplies(_ text: String) -> [String: Set<Int>]? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = "<send_user_message_question_reply>"
        let end = "</send_user_message_question_reply>"
        guard text.hasPrefix(start) else { return nil }
        var body = String(text.dropFirst(start.count))
        if body.hasSuffix(end) { body = String(body.dropLast(end.count)) }
        guard let rows = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [[String: Any]] else { return [:] }
        var replies: [String: Set<Int>] = [:]
        for row in rows {
            guard let item = row["questionItemId"] as? String,
                  let identity = (try? JSONSerialization.jsonObject(with: Data(item.utf8))) as? [Any], identity.count == 3,
                  let tool = identity[0] as? String, shortTool(tool) == "request_user_input_async",
                  let call = identity[1] as? String, let index = identity[2] as? NSNumber,
                  !["c", "d", "f"].contains(String(cString: index.objCType)), index.intValue >= 0 else { continue }
            replies[call, default: []].insert(index.intValue)
        }
        return replies
    }

    static func deliveryRejected(_ value: Any?) -> Bool {
        let response: Any?
        if let text = value as? String {
            response = try? JSONSerialization.jsonObject(with: Data(text.utf8))
        } else {
            response = value
        }
        guard let object = response as? [String: Any], let flag = object["accepted"] as? NSNumber,
              String(cString: flag.objCType) == "c" else { return false }
        return !flag.boolValue
    }

    static func codexEvidence(_ rows: [[String: Any]]) -> Evidence? {
        var pending: [String: Set<Int>] = [:]
        var asynchronous = Set<String>()
        var result: Evidence?
        var resolved = false
        for row in rows {
            guard let current = parse(row, agent: "codex"), let payload = row["payload"] as? [String: Any] else { continue }
            let event = payload["type"] as? String ?? ""
            let type = row["type"] as? String ?? ""
            let call = payload["call_id"] as? String ?? "missing_call_id"
            if current.state == "idle" || (type == "event_msg" && event == "task_started") {
                // An asynchronous question outlives the turn that asked it: only its answer or a new prompt ends it.
                pending = pending.filter { asynchronous.contains($0.key) }
                asynchronous.formIntersection(pending.keys)
                resolved = false
            }
            var prompt: String?
            if type == "response_item", event == "message", payload["role"] as? String == "user" {
                let blocks = payload["content"] as? [[String: Any]] ?? []
                prompt = typedPrompt(blocks.compactMap { $0["text"] as? String })
            } else if type == "event_msg", event == "user_message" {
                prompt = payload["message"] as? String
            }
            if let prompt {
                if let replies = questionReplies(prompt) {
                    for (identity, indices) in replies {
                        guard let unanswered = pending[identity] else { continue }
                        let remaining = unanswered.subtracting(indices)
                        if remaining.isEmpty {
                            pending.removeValue(forKey: identity)
                            asynchronous.remove(identity)
                            resolved = true
                        } else {
                            pending[identity] = remaining
                        }
                    }
                } else {
                    pending.removeAll()
                    asynchronous.removeAll()
                    resolved = true
                }
            }
            if type == "response_item", ["function_call", "custom_tool_call"].contains(event), current.state == "waiting" {
                let tool = shortTool(payload["name"] as? String ?? "")
                let raw = payload["arguments"] as? String ?? payload["input"] as? String ?? "{}"
                let input = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
                let count = max(1, (input?["questions"] as? [Any])?.count ?? 1)
                pending[call] = Set(0..<count)
                if tool == "request_user_input_async" { asynchronous.insert(call) }
                resolved = false
            }
            if type == "response_item", ["function_call_output", "custom_tool_call_output"].contains(event),
               (!asynchronous.contains(call) || deliveryRejected(payload["output"])), pending.removeValue(forKey: call) != nil {
                asynchronous.remove(call)
                resolved = true
            }
            result = Evidence(state: pending.isEmpty ? current.state : "waiting", date: current.date,
                              clearsWaiting: resolved && pending.isEmpty)
        }
        return result
    }

    static func read(_ url: URL, agent: String) -> Evidence? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > 1_048_576 ? size - 1_048_576 : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: 10, omittingEmptySubsequences: false)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        if data.last != 10, !lines.isEmpty { lines.removeLast() }
        if agent == "codex" {
            let rows = lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
            return codexEvidence(rows)
        }
        for line in lines.reversed() {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            if let evidence = parse(row, agent: agent) { return evidence }
        }
        return nil
    }
}

// StatusStore permits only one background refresh to access this cache at a time.
final class EvidenceReader: @unchecked Sendable {
    private let home: URL
    private var paths: [String: URL] = [:]
    private var scannedAt = Date.distantPast
    private var cache: [String: (Date, Int, Evidence?)] = [:]
    private(set) var codexNames: [String: String] = [:]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    func refreshIndex(now: Date = Date()) {
        guard now.timeIntervalSince(scannedAt) > 30 else { return }
        let started = ProcessInfo.processInfo.systemUptime
        Diagnostics.emit("evidence.index_start")
        defer { Diagnostics.emit("evidence.index_end", fields: ["elapsed_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000, "row_count": paths.count]) }
        scannedAt = now
        let codex = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        if let text = try? String(contentsOf: codex.appendingPathComponent("session_index.jsonl"), encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let id = row["id"] as? String, let name = row["thread_name"] as? String else { continue }
                codexNames[id] = name
            }
        }
        for (agent, root) in [("claude", home.appendingPathComponent(".claude/projects")), ("codex", codex.appendingPathComponent("sessions"))] {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let name = url.deletingPathExtension().lastPathComponent
                if agent == "claude" && UUID(uuidString: name) != nil { paths["claude-\(name)"] = url }
                if agent == "codex", name.count >= 36, UUID(uuidString: String(name.suffix(36))) != nil {
                    paths["codex-\(name.suffix(36))"] = url
                }
            }
        }
    }

    func evidence(agent: String, id: String) -> Evidence? {
        let key = "\(agent)-\(id)"
        guard let url = paths[key], let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date, let size = attributes[.size] as? Int else {
            Diagnostics.emit("evidence.missing", agent: agent, fields: ["session_id": id])
            return nil
        }
        if let previous = cache[key], previous.0 == modified && previous.1 == size { return previous.2 }
        let started = ProcessInfo.processInfo.systemUptime
        let result = SessionEvidence.read(url, agent: agent)
        var fields: [String: Any] = ["session_id": id, "elapsed_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000]
        if let result { fields["evidence_state"] = result.state; fields["evidence_ms"] = result.date.timeIntervalSince1970 * 1000 }
        Diagnostics.emit("evidence.read", agent: agent, fields: fields)
        cache[key] = (modified, size, result)
        return result
    }
}

enum Reconcile {
    static func titleName(_ title: String) -> String {
        var title = title
        if let first = title.unicodeScalars.first,
           (0x2800...0x28ff).contains(first.value), let space = title.firstIndex(of: " ") {
            title = String(title[title.index(after: space)...])
        }
        guard let separator = title.range(of: " | ", options: .backwards) else { return title }
        return String(title[..<separator.lowerBound])
    }

    static func claudeActivity(_ title: String) -> String? {
        if title.hasPrefix("✳ ") { return "idle" }
        if ["◐ ", "◓ ", "◑ ", "◒ "].contains(where: title.hasPrefix) { return "working" }
        return nil
    }

    static func state(_ original: SessionStatus, place: TerminalPlace?, evidence: Evidence?, now: Date) -> SessionStatus {
        var result = original
        var reason = "hook_retained"
        defer { if Diagnostics.enabled {
            var fields: [String: Any] = ["session_id": original.sessionId, "hook_state": original.state,
                                       "state": result.state, "reason": reason]
            if let id = original.ghosttyTerminalId { fields["terminal_id"] = id }
            if let date = timestamp(original.updatedAt) { fields["reported_ms"] = date.timeIntervalSince1970 * 1000 }
            if let evidence {
                fields["evidence_state"] = evidence.state
                fields["evidence_ms"] = evidence.date.timeIntervalSince1970 * 1000
            }
            Diagnostics.emit("sidebar.reconcile", agent: original.agent, fields: fields)
        } }
        guard original.state != "done" else { return result }
        let reported = timestamp(original.updatedAt) ?? .distantPast
        if let evidence {
            let permission = original.message == "permission" || original.message?.hasPrefix("permission: ") == true
            let unresolvedQuestion = original.agent == "codex" && original.state == "waiting" && !permission
                && evidence.state == "working" && !evidence.clearsWaiting
            if evidence.date > reported.addingTimeInterval(1), evidence.state != original.state, !unresolvedQuestion {
                result.state = evidence.state
                reason = "newer_evidence"
                result.message = evidence.state == "waiting" ? "Question awaiting an answer" : nil
            }
            // A hook that lost the lock race to Stop can leave a finished turn on working.
            if original.agent == "claude", evidence.state == "idle", result.state == "working",
               now.timeIntervalSince(evidence.date) > 3, now.timeIntervalSince(reported) > 3,
               place.flatMap({ claudeActivity($0.title) }) == "idle" {
                result.state = "idle"
                reason = "finished_turn_title"
                result.message = nil
            }
        } else if now.timeIntervalSince(reported) > 15, original.state == "working",
                  original.agent == "claude", place.flatMap({ claudeActivity($0.title) }) == "idle" {
            result.state = "idle"
            reason = "idle_title_fallback"
            result.message = "Idle in terminal"
        }
        return result
    }

    static func sessions(_ records: [SessionStatus], layout: TabLayout?, names: [String: String],
                         evidence: (String, String) -> Evidence?, now: Date = Date(), alive: (Int32) -> Bool = processAlive) -> [SessionStatus] {
        var rows: [String: SessionStatus] = [:]
        var unplaced: [SessionStatus] = []
        for record in records.sorted(by: { (timestamp($0.updatedAt) ?? .distantPast) < (timestamp($1.updatedAt) ?? .distantPast) }) {
            if record.state == "done" {
                guard let date = timestamp(record.updatedAt), now.timeIntervalSince(date) < 180 else { continue }
            } else if let pid = record.pid, !alive(pid) { continue }
            if let id = record.ghosttyTerminalId {
                if let layout, layout.places[id] == nil { continue }
                rows[id] = state(record, place: layout?.places[id], evidence: evidence(record.agent, record.sessionId), now: now)
            } else {
                unplaced.append(record)
            }
        }
        if let layout {
            for (id, place) in layout.places where rows[id] == nil {
                let title = titleName(place.title)
                let matches = names.filter { $0.value == title && place.title.contains(" | ") }
                if matches.isEmpty {
                    guard let activity = claudeActivity(place.title) else { continue }
                    guard !unplaced.contains(where: { $0.agent == "claude" }) else { continue }
                    let name = String(place.title.dropFirst(2))
                    rows[id] = SessionStatus(agent: "claude", sessionId: id, state: activity,
                        title: name.isEmpty ? "Claude Code" : name, cwd: place.cwd, repo: nil, branch: nil, color: nil,
                        ghosttyTerminalId: id, pid: nil, updatedAt: nil, message: "Status from terminal title")
                    continue
                }
                let unique = matches.count == 1 && layout.places.values.filter { titleName($0.title) == title }.count == 1
                let sessionId = unique ? matches.first!.key : id
                let agent = unique ? "codex" : "terminal"
                let source = evidence(agent, sessionId)
                let matching = unplaced.filter { $0.agent == agent && $0.sessionId == sessionId }
                if let record = matching.last {
                    var placed = record
                    placed.ghosttyTerminalId = id
                    rows[id] = state(placed, place: place, evidence: source, now: now)
                    unplaced.removeAll { $0.id == record.id }
                } else {
                    rows[id] = SessionStatus(agent: agent, sessionId: sessionId, state: source?.state ?? "unknown",
                        title: title.isEmpty ? "Terminal" : title, cwd: place.cwd, repo: nil, branch: nil, color: nil,
                        ghosttyTerminalId: id, pid: nil, updatedAt: source.map { ISO8601DateFormatter().string(from: $0.date) },
                        message: source == nil ? "No session status available" : "Status from session activity")
                }
            }
        }
        let placedIDs = Set(rows.values.map(\.id))
        return Array(rows.values) + unplaced.filter { !placedIDs.contains($0.id) }
    }
}
