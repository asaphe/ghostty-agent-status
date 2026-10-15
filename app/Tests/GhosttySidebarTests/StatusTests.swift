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
        tests.testBackgroundTaskDisplayDoesNotChangeTurnState()
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
        tests.testCodexAsyncDeliveryRetainsWaitThroughOtherWork()
        tests.testCodexBlockingCompletionClearsWait()
        tests.testCodexStructuredRepliesClearOnlyAnsweredItems()
        tests.testCodexPlainReplyRemainsWorkingThroughOtherCalls()
        tests.testCodexTerminalEventsCancelUnansweredQuestions()
        tests.testCodexUnrelatedEvidenceCannotOverridePendingHook()
        tests.testCodexRejectedAsyncDeliveryClearsWait()
        tests.testTitleProbeDoesNotBreakIdentity()
        tests.testTwoTabsWithSameTitleAreAmbiguous()
        tests.testSubsecondTranscriptCannotOverridePermissionHook()
        try tests.testPartialTranscriptLineDoesNotDiscardLastCompleteEvent()
        tests.testPanelSitsBesideWindowWhenThereIsRoom()
        tests.testWindowIsSqueezedOnlyWhenAsked()
        tests.testAdjacentWindowsReserveTheirOwnSidebarSpace()
        tests.testReservationFitsOnNegativeCoordinateDisplay()
        tests.testNarrowReservationStaysInsideItsWindow()
        tests.testOversizedSidebarStaysInsideItsWindow()
        tests.testNarrowWindowIsNotSqueezed()
        tests.testFullScreenWindowGetsOverlay()
        tests.testPanelFollowsWindowOnSecondScreen()
        tests.testDropTargetPrefersLargestOverlapAndReachesBesideWindow()
        tests.testWindowTitleMatchesOnlyWhenUnique()
        print("42 status tests passed")
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
    func testBackgroundTaskDisplayDoesNotChangeTurnState() {
        for message in ["1 background task running", "2 background tasks running"] {
            var session = record("idle")
            session.message = message
            XCTAssertEqual(session.displayState, "background")
            XCTAssertEqual(session.state, "idle")
            session.state = "waiting"
            XCTAssertEqual(session.displayState, "waiting")
            session.state = "working"
            XCTAssertEqual(session.displayState, "working")
        }
        for message in ["0 background tasks running", "background tasks running", "turn failed", "1 background tasks running"] {
            var session = record("idle")
            session.message = message
            XCTAssertEqual(session.displayState, "idle")
        }
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
    func codexRows(_ payloads: [[String: Any]]) -> [[String: Any]] {
        payloads.enumerated().map { index, payload in
            ["timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(950 + index))),
             "type": ["task_started", "task_complete", "turn_aborted", "user_message"].contains(payload["type"] as? String ?? "") ? "event_msg" : "response_item",
             "payload": payload]
        }
    }
    func codexQuestion(_ call: String = "q", asynchronous: Bool = true, count: Int = 1) -> [String: Any] {
        let arguments = String(data: try! JSONSerialization.data(withJSONObject: ["questions": Array(repeating: ["title": "Choose"], count: count)]), encoding: .utf8)!
        return ["type": "function_call", "name": asynchronous ? "functions.request_user_input_async" : "functions.request_user_input",
                "call_id": call, "arguments": arguments]
    }
    func questionReply(_ call: String, index: Int = 0) -> [String: Any] {
        let item = String(data: try! JSONSerialization.data(withJSONObject: ["request_user_input_async", call, index]), encoding: .utf8)!
        return questionReplyID(item)
    }
    func questionReplyID(_ item: String) -> [String: Any] {
        let body = String(data: try! JSONSerialization.data(withJSONObject: [["answer": "Red", "questionItemId": item]]), encoding: .utf8)!
        return ["type": "message", "role": "user", "content": [["type": "input_text", "text": "<send_user_message_question_reply>\(body)</send_user_message_question_reply>"]]]
    }
    func testCodexAsyncDeliveryRetainsWaitThroughOtherWork() {
        let rows = codexRows([codexQuestion(), ["type": "function_call_output", "call_id": "q", "output": "{\"accepted\":true}"],
                              ["type": "function_call", "name": "sleep", "call_id": "sleep"],
                              ["type": "function_call_output", "call_id": "sleep"]])
        for end in 1...rows.count {
            XCTAssertEqual(SessionEvidence.codexEvidence(Array(rows.prefix(end)))?.state, "waiting")
        }
    }
    func testCodexBlockingCompletionClearsWait() {
        let evidence = SessionEvidence.codexEvidence(codexRows([codexQuestion(asynchronous: false),
                                                               ["type": "function_call_output", "call_id": "q"]]))
        XCTAssertEqual(evidence?.state, "working")
        XCTAssertEqual(evidence?.clearsWaiting, true)
    }
    func testCodexStructuredRepliesClearOnlyAnsweredItems() {
        var payloads = [codexQuestion(count: 2), codexQuestion("other"), questionReply("q")]
        XCTAssertEqual(SessionEvidence.codexEvidence(codexRows(payloads))?.state, "waiting")
        payloads += [questionReply("q", index: 1), questionReply("unknown")]
        XCTAssertEqual(SessionEvidence.codexEvidence(codexRows(payloads))?.state, "waiting")
        payloads += [questionReply("other")]
        XCTAssertEqual(SessionEvidence.codexEvidence(codexRows(payloads))?.state, "working")
        let malformed: [String: Any] = ["type": "user_message", "message": "<send_user_message_question_reply>bad"]
        XCTAssertEqual(SessionEvidence.codexEvidence(codexRows([codexQuestion(), malformed]))?.state, "waiting")
        for invalid in ["true", "-1", "0.0"] {
            let item = "[\"request_user_input_async\",\"q\",\(invalid)]"
            XCTAssertEqual(SessionEvidence.codexEvidence(codexRows([codexQuestion(), questionReplyID(item)]))?.state, "waiting")
        }
    }
    func testCodexPlainReplyRemainsWorkingThroughOtherCalls() {
        for reply: [String: Any] in [["type": "user_message", "message": "Red"],
                                    ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Red"]]]] {
            let evidence = SessionEvidence.codexEvidence(codexRows([codexQuestion(), reply,
                                                                   ["type": "function_call", "name": "Bash", "call_id": "work"],
                                                                   ["type": "function_call_output", "call_id": "work"]]))
            XCTAssertEqual(evidence?.state, "working")
            XCTAssertEqual(evidence?.clearsWaiting, true)
        }
    }
    func testCodexTerminalEventsCancelUnansweredQuestions() {
        for end: [String: Any] in [["type": "task_complete"], ["type": "turn_aborted"],
                                  ["type": "message", "role": "assistant", "phase": "final_answer"]] {
            XCTAssertEqual(SessionEvidence.codexEvidence(codexRows([codexQuestion(), end]))?.state, "idle")
            XCTAssertEqual(SessionEvidence.codexEvidence(codexRows([codexQuestion(), end, ["type": "task_started"]]))?.state, "working")
        }
    }
    func testCodexUnrelatedEvidenceCannotOverridePendingHook() {
        var session = record("waiting")
        session.agent = "codex"
        let unrelated = Evidence(state: "working", date: Date(timeIntervalSince1970: 950))
        XCTAssertEqual(rows([session], layout(), source: unrelated).first?.state, "waiting")
        let answer = Evidence(state: "working", date: Date(timeIntervalSince1970: 950), clearsWaiting: true)
        XCTAssertEqual(rows([session], layout(), source: answer).first?.state, "working")
    }
    func testCodexRejectedAsyncDeliveryClearsWait() {
        for (output, expected) in [("{\"accepted\":false}", "working"), ("{\"accepted\":true}", "waiting"),
                                   ("{\"accepted\":0}", "waiting"), ("unknown", "waiting")] {
            let evidence = SessionEvidence.codexEvidence(codexRows([codexQuestion(), ["type": "function_call_output", "call_id": "q", "output": output]]))
            XCTAssertEqual(evidence?.state, expected)
        }
    }

    let screen = CGRect(x: 0, y: 25, width: 1920, height: 1055)

    func testPanelSitsBesideWindowWhenThereIsRoom() {
        let place = Placement.place(window: CGRect(x: 100, y: 100, width: 1000, height: 600), fullScreen: false,
                                    screen: screen, width: 280, squeeze: true)
        XCTAssertEqual(place, PanelPlacement(panel: CGRect(x: 1100, y: 100, width: 280, height: 600)))
    }
    func testWindowIsSqueezedOnlyWhenAsked() {
        let window = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        XCTAssertEqual(Placement.place(window: window, fullScreen: false, screen: screen, width: 280, squeeze: true),
                       PanelPlacement(panel: CGRect(x: 1640, y: 25, width: 280, height: 1055),
                                      window: CGRect(x: 0, y: 25, width: 1640, height: 1055)))
        XCTAssertEqual(Placement.place(window: window, fullScreen: false, screen: screen, width: 280, squeeze: false),
                       PanelPlacement(panel: CGRect(x: 1640, y: 25, width: 280, height: 1055)))
    }
    func testNarrowWindowIsNotSqueezed() {
        let place = Placement.place(window: CGRect(x: 1500, y: 25, width: 420, height: 800), fullScreen: false,
                                    screen: screen, width: 280, squeeze: true)
        XCTAssertNil(place.window)
        XCTAssertEqual(place.panel, CGRect(x: 1640, y: 25, width: 280, height: 800))
    }
    func testAdjacentWindowsReserveTheirOwnSidebarSpace() {
        let footprints = [CGRect(x: 0, y: 25, width: 960, height: 1055),
                          CGRect(x: 960, y: 25, width: 960, height: 1055)]
        let places = footprints.map {
            Placement.place(window: $0, fullScreen: false, screen: screen, width: 280,
                            squeeze: true, reserveInside: true)
        }
        for (footprint, place) in zip(footprints, places) {
            XCTAssertEqual(place.window?.width, 680)
            XCTAssertEqual(place.window?.minX, footprint.minX)
            XCTAssertEqual(place.window?.maxX, place.panel.minX)
            XCTAssertEqual(place.panel.maxX, footprint.maxX)
            XCTAssertTrue(footprint.contains(place.panel))
        }
        XCTAssertTrue(!places[0].panel.intersects(places[1].window!))
        XCTAssertTrue(!places[1].panel.intersects(places[0].window!))
        XCTAssertTrue(!places[0].panel.intersects(places[1].panel))
    }
    func testReservationFitsOnNegativeCoordinateDisplay() {
        let display = CGRect(x: -1920, y: -1055, width: 1920, height: 1055)
        let footprint = CGRect(x: -1920, y: -1055, width: 960, height: 1055)
        let place = Placement.place(window: footprint, fullScreen: false, screen: display, width: 280,
                                    squeeze: true, reserveInside: true)
        XCTAssertEqual(place.window, CGRect(x: -1920, y: -1055, width: 680, height: 1055))
        XCTAssertEqual(place.panel, CGRect(x: -1240, y: -1055, width: 280, height: 1055))
    }
    func testNarrowReservationStaysInsideItsWindow() {
        let footprint = CGRect(x: 0, y: 25, width: 420, height: 800)
        let place = Placement.place(window: footprint, fullScreen: false, screen: screen, width: 280,
                                    squeeze: true, reserveInside: true)
        XCTAssertNil(place.window)
        XCTAssertTrue(footprint.contains(place.panel))
    }
    func testOversizedSidebarStaysInsideItsWindow() {
        let footprint = CGRect(x: 0, y: 25, width: 420, height: 800)
        let place = Placement.place(window: footprint, fullScreen: false, screen: screen, width: 600,
                                    squeeze: true, reserveInside: true)
        XCTAssertNil(place.window)
        XCTAssertTrue(footprint.contains(place.panel))
        XCTAssertEqual(place.panel.width, 420)
    }
    func testFullScreenWindowGetsOverlay() {
        let window = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(Placement.place(window: window, fullScreen: true, screen: screen, width: 280, squeeze: true),
                       PanelPlacement(panel: CGRect(x: 1640, y: 0, width: 280, height: 1080)))
    }
    func testPanelFollowsWindowOnSecondScreen() {
        let left = CGRect(x: -1026, y: -1080, width: 1920, height: 1080)
        let right = CGRect(x: 894, y: -1080, width: 1920, height: 1080)
        let window = CGRect(x: 894, y: -1050, width: 1640, height: 1050)
        XCTAssertEqual(Placement.screen(for: window, among: [screen, left, right]), right)
        XCTAssertEqual(Placement.place(window: window, fullScreen: false, screen: right, width: 280, squeeze: true),
                       PanelPlacement(panel: CGRect(x: 2534, y: -1050, width: 280, height: 1050)))
    }
    func testDropTargetPrefersLargestOverlapAndReachesBesideWindow() {
        let windows = [CGRect(x: 0, y: 0, width: 800, height: 800), CGRect(x: 1000, y: 0, width: 800, height: 800)]
        XCTAssertEqual(Placement.dropTarget(panel: CGRect(x: 950, y: 0, width: 280, height: 800), windows: windows), 1)
        XCTAssertEqual(Placement.dropTarget(panel: CGRect(x: 820, y: 0, width: 150, height: 800), windows: windows), 0)
        XCTAssertNil(Placement.dropTarget(panel: CGRect(x: 3000, y: 0, width: 280, height: 800), windows: windows))
    }
    func testWindowTitleMatchesOnlyWhenUnique() {
        let layout = TabLayout(windowNames: ["W1": "zsh", "W2": "zsh", "W3": "Task"])
        XCTAssertEqual(layout.windowId(titled: "Task"), "W3")
        XCTAssertNil(layout.windowId(titled: "zsh"))
        XCTAssertNil(layout.windowId(titled: "missing"))
        let glyphs = TabLayout(windowNames: ["W1": "⏳🟩 Fix sidebar · [repo]", "W2": "~/git/repo"])
        XCTAssertEqual(glyphs.windowId(titled: "✋🟩 Fix sidebar · [repo]"), "W1")
        XCTAssertEqual(glyphs.windowId(titled: "~/git/repo"), "W2")
    }
}
