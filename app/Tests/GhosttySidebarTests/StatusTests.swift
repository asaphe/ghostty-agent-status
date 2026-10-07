import Foundation

func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) {
    precondition(a == b, "Expected \(b), got \(a)", file: file, line: line)
}
func XCTAssertNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(value == nil, "Expected nil", file: file, line: line)
}
func XCTAssertNotNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(value != nil, "Expected non-nil", file: file, line: line)
}
func XCTAssertTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(value, "Expected true", file: file, line: line)
}

@main
final class StatusTests {
    static func main() throws {
        let tests = StatusTests()
        tests.testCompletedTurnRepairsLateBackgroundWorkingEvent()
        tests.testBackgroundTasksLeaveTheTurnIdleWithTheHookMessage()
        tests.testDeniedOrInterruptedTurnEndsWaiting()
        tests.testPermissionWaitSurvivesOlderToolCall()
        tests.testNewToolResultClearsPermissionWait()
        tests.testOneNewestSessionPerTerminal()
        tests.testClosedTerminalDoesNotLeaveGhostRow()
        tests.testMissingCodexHookRecoveredFromSession()
        tests.testTerminalWithoutAgentIsHidden()
        tests.testClaudeTabWithoutRecordIsShownFromTitle()
        tests.testUnplacedClaudeRecordPreventsConflictingFallback()
        tests.testAmbiguousClaudeTabsKeepUnplacedRecords()
        tests.testOtherRecordsDoNotBlockClaudeFallback()
        tests.testExpiredUnplacedRecordDoesNotBlockClaudeFallback()
        tests.testAmbiguousCodexNamesAreNotAssigned()
        tests.testFractionalTimestampsAndDoneGrace()
        tests.testCodexSpinnerDoesNotBecomePartOfIdentity()
        tests.testClaudeTranscriptSkipsSidechainAndAwaySummary()
        tests.testCodexTurnLifecycle()
        tests.testTitleProbeDoesNotBreakIdentity()
        tests.testTwoTabsWithSameTitleAreAmbiguous()
        tests.testSubsecondTranscriptCannotOverridePermissionHook()
        try tests.testPartialTranscriptLineDoesNotDiscardLastCompleteEvent()
        print("23 status tests passed")
    }

    let now = Date(timeIntervalSince1970: 1000)
    func record(_ state: String = "working", terminal: String? = "T", seconds: Double = 900) -> SessionStatus {
        SessionStatus(agent: "claude", sessionId: "S", state: state, title: "Task", cwd: "/repo", repo: "repo",
                      branch: nil, color: nil, ghosttyTerminalId: terminal, pid: 42,
                      updatedAt: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds)), message: "old")
    }
    func layout(_ title: String = "✳ Task") -> TabLayout {
        TabLayout(places: ["T": TerminalPlace(windowId: "W", tabIndex: 1, splitIndex: 1, title: title)],
                  frontWindowId: "W", tabCounts: ["W": 1])
    }
    func rows(_ records: [SessionStatus], _ live: TabLayout = TabLayout(), names: [String: String] = [:],
              source: Evidence? = nil) -> [SessionStatus] {
        Reconcile.sessions(records, layout: live, names: names, evidence: { _, _ in source }, now: now, alive: { _ in true })
    }
    func testCompletedTurnRepairsLateBackgroundWorkingEvent() {
        let r = rows([record()], layout(), source: Evidence(state: "idle", date: Date(timeIntervalSince1970: 850)))
        XCTAssertEqual(r.first?.state, "idle")
        XCTAssertNil(r.first?.message)
    }
    func testBackgroundTasksLeaveTheTurnIdleWithTheHookMessage() {
        let r = rows([record("idle")], layout("◑ Task"), source: Evidence(state: "idle", date: Date(timeIntervalSince1970: 950)))
        XCTAssertEqual(r.first?.state, "idle")
        XCTAssertEqual(r.first?.message, "old")
    }
    func testDeniedOrInterruptedTurnEndsWaiting() {
        let interrupt: [String: Any] = ["timestamp": "2026-10-07T09:00:00Z", "type": "user",
                                        "message": ["content": [["type": "text", "text": "[Request interrupted by user for tool use]"]]]]
        let result: [String: Any] = ["timestamp": "2026-10-07T09:00:00Z", "type": "user",
                                     "message": ["content": [["type": "tool_result", "content": "ok"]]]]
        let turnEnd: [String: Any] = ["timestamp": "2026-10-07T09:00:00Z", "type": "system", "subtype": "turn_duration"]
        XCTAssertEqual(SessionEvidence.parse(interrupt, agent: "claude")?.state, "idle")
        XCTAssertEqual(SessionEvidence.parse(result, agent: "claude")?.state, "working")
        XCTAssertEqual(SessionEvidence.parse(turnEnd, agent: "claude")?.state, "idle")
        let r = rows([record("waiting")], layout(), source: Evidence(state: "idle", date: Date(timeIntervalSince1970: 950)))
        XCTAssertEqual(r.first?.state, "idle")
    }
    func testPermissionWaitSurvivesOlderToolCall() {
        let r = rows([record("waiting")], layout(), source: Evidence(state: "working", date: Date(timeIntervalSince1970: 850)))
        XCTAssertEqual(r.first?.state, "waiting")
    }
    func testNewToolResultClearsPermissionWait() {
        let r = rows([record("waiting")], layout(), source: Evidence(state: "working", date: Date(timeIntervalSince1970: 950)))
        XCTAssertEqual(r.first?.state, "working")
        XCTAssertNil(r.first?.message)
    }
    func testOneNewestSessionPerTerminal() {
        var newer = record("idle", seconds: 950)
        newer.sessionId = "new"
        let r = rows([newer, record()], layout())
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.sessionId, "new")
    }
    func testClosedTerminalDoesNotLeaveGhostRow() {
        XCTAssertTrue(rows([record()]).isEmpty)
    }
    func testMissingCodexHookRecoveredFromSession() {
        let r = rows([], layout("Task | repo"), names: ["codex-session": "Task"], source: Evidence(state: "idle", date: now))
        XCTAssertEqual(r.first?.agent, "codex")
        XCTAssertEqual(r.first?.state, "idle")
        XCTAssertEqual(r.first?.ghosttyTerminalId, "T")
    }
    func testTerminalWithoutAgentIsHidden() {
        XCTAssertTrue(rows([], layout("zsh")).isEmpty)
        XCTAssertTrue(rows([], layout("Task | repo"), names: ["S": "Other"]).isEmpty)
    }
    func testClaudeTabWithoutRecordIsShownFromTitle() {
        let working = rows([], layout("◑ Task"))
        XCTAssertEqual(working.count, 1)
        XCTAssertEqual(working.first?.agent, "claude")
        XCTAssertEqual(working.first?.state, "working")
        XCTAssertEqual(working.first?.title, "Task")
        XCTAssertEqual(working.first?.ghosttyTerminalId, "T")
        XCTAssertEqual(rows([], layout("✳ Task")).first?.state, "idle")
    }
    func testUnplacedClaudeRecordPreventsConflictingFallback() {
        for title in ["✳ Task", "◑ Task"] {
            let waiting = record("waiting", terminal: nil)
            XCTAssertEqual(rows([waiting], layout(title)), [waiting])
        }
    }
    func testAmbiguousClaudeTabsKeepUnplacedRecords() {
        let waiting = record("waiting", terminal: nil)
        var other = record("working", terminal: nil)
        other.sessionId = "other"
        other.cwd = "/other"
        var live = layout("✳ Task")
        live.places["T2"] = TerminalPlace(windowId: "W", tabIndex: 2, splitIndex: 1, title: "◑ Task", cwd: "/other")
        let result = rows([waiting, other], live)
        XCTAssertEqual(Set(result.map(\.id)), Set([waiting.id, other.id]))
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.ghosttyTerminalId == nil })
        XCTAssertEqual(result.first { $0.id == waiting.id }?.state, "waiting")
    }
    func testOtherRecordsDoNotBlockClaudeFallback() {
        var live = layout("◑ Task")
        live.places["T2"] = TerminalPlace(windowId: "W", tabIndex: 2, splitIndex: 1, title: "✳ Other")
        let placed = record("waiting", terminal: "T2")
        var codex = record("waiting", terminal: nil)
        codex.agent = "codex"
        let result = rows([placed, codex], live)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.first { $0.ghosttyTerminalId == "T" }?.state, "working")
        XCTAssertEqual(result.first { $0.id == placed.id }, placed)
        XCTAssertEqual(result.first { $0.id == codex.id }, codex)
    }
    func testExpiredUnplacedRecordDoesNotBlockClaudeFallback() {
        let result = rows([record("done", terminal: nil, seconds: 100)], layout("◑ Task"))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.ghosttyTerminalId, "T")
        XCTAssertEqual(result.first?.state, "working")
    }
    func testAmbiguousCodexNamesAreNotAssigned() {
        let r = rows([], layout("Task | repo"), names: ["A": "Task", "B": "Task"])
        XCTAssertEqual(r.first?.agent, "terminal")
    }
    func testFractionalTimestampsAndDoneGrace() {
        XCTAssertNotNil(timestamp("2026-10-07T09:00:00.123Z"))
        XCTAssertNotNil(timestamp("2026-10-07T09:00:00Z"))
        XCTAssertEqual(rows([record("done")], layout()).first?.state, "done")
        XCTAssertTrue(rows([record("done", seconds: 100)], layout("zsh")).isEmpty)
    }
    func testCodexSpinnerDoesNotBecomePartOfIdentity() {
        XCTAssertEqual(Reconcile.titleName("⠧ Task | repo"), "Task")
        XCTAssertEqual(Reconcile.titleName("Task | repo"), "Task")
    }
    func testTitleProbeDoesNotBreakIdentity() {
        XCTAssertEqual(layout("tty-probe-abc").preservingTitles(from: layout("Task | repo")).places["T"]?.title, "Task | repo")
        XCTAssertEqual(layout("zsh").preservingTitles(from: layout("Task | repo")).places["T"]?.title, "zsh")
    }
    func testTwoTabsWithSameTitleAreAmbiguous() {
        var live = layout("Task | repo")
        live.places["T2"] = TerminalPlace(windowId: "W", tabIndex: 2, splitIndex: 1, title: "Task | repo")
        let result = rows([], live, names: ["S": "Task"])
        XCTAssertEqual(result.filter { $0.agent == "terminal" }.count, 2)
        XCTAssertEqual(Set(result.map(\.id)).count, 2)
    }
    func testSubsecondTranscriptCannotOverridePermissionHook() {
        let result = rows([record("waiting")], layout(), source: Evidence(state: "working", date: Date(timeIntervalSince1970: 900.8)))
        XCTAssertEqual(result.first?.state, "waiting")
    }
    func testClaudeTranscriptSkipsSidechainAndAwaySummary() {
        let row: [String: Any] = ["timestamp": "2026-10-07T09:00:00Z", "type": "assistant",
                                  "message": ["stop_reason": "end_turn"]]
        XCTAssertEqual(SessionEvidence.parse(row, agent: "claude")?.state, "idle")
        XCTAssertNil(SessionEvidence.parse(row.merging(["isSidechain": true]) { _, b in b }, agent: "claude"))
        XCTAssertNil(SessionEvidence.parse(["timestamp": "2026-10-07T09:00:00Z", "type": "system", "subtype": "away_summary"], agent: "claude"))
    }
    func testCodexTurnLifecycle() {
        for (event, state) in [("task_started", "working"), ("task_complete", "idle"), ("turn_aborted", "idle")] {
            let row: [String: Any] = ["timestamp": "2026-10-07T09:00:00Z", "type": "event_msg", "payload": ["type": event]]
            XCTAssertEqual(SessionEvidence.parse(row, agent: "codex")?.state, state)
        }
    }
    func testPartialTranscriptLineDoesNotDiscardLastCompleteEvent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"timestamp\":\"2026-10-07T09:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n{\"type\":".utf8).write(to: url)
        XCTAssertEqual(SessionEvidence.read(url, agent: "codex")?.state, "idle")
    }
}
