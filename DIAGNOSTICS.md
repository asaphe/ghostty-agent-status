# Diagnosing status latency and incorrect states

Diagnostics observe the current behavior. They do not change state decisions, polling intervals, hook registrations or installed copies. Investigate Claude and Codex separately, and compare a successful transition with a failing transition for each agent.

## Coverage and activation

Run commands from the instrumented source checkout. The installed hook scripts and sidebar must include the instrumentation before they can produce hook, worker or sidebar events. Enabling diagnostics alone does not upgrade those copies. Reports list producer/source fingerprints so a capture from the wrong copy is visible. Python fingerprints cover the five diagnostic/hook scripts; the sidebar fingerprint covers its executable. These are different fingerprints, not release numbers.

```sh
python3 scripts/diagnostics.py enable
python3 scripts/diagnostics.py report --tail 10
python3 scripts/diagnostics.py disable
```

The default output is `<state directory>/diagnostics`. The state directory is `GHOSTTY_AGENT_STATUS_DIR`, or the existing default described in README. A shared `enabled` marker takes effect on the next operation without restarting an instrumented process. `GHOSTTY_AGENT_STATUS_DIAGNOSTICS=1` enables diagnostics for that process and its workers; `0` disables them and overrides the marker. `GHOSTTY_AGENT_STATUS_DIAGNOSTICS_DIR` redirects trace output and the marker without redirecting status reads. A sidebar launched by the desktop may not inherit shell environment variables; use the marker in its default directory or launch the instrumented executable with matching environment variables.

An existing uninstrumented session can still be observed using `watch` and `sample`. This is partial coverage: it cannot establish when its hook ran or why its worker failed. The report's `coverage` flags check specific hook, worker, sidebar and observer stages; a Python producer alone does not establish hook coverage. Do not interpret absence of hook events in an observer-only capture as missing hooks.

To preserve running tabs, Claude can load the diagnostic plugin with `--plugin-dir` in a fresh session. For Codex, use the exact-session dispatcher with a staged script directory, preserving the normal shared daemon and existing hook command. Register only the new test session with `route codex SESSION_ID --source /absolute/scripts --output /absolute/capture`; remove it afterward with `unroute codex SESSION_ID`. The installed entrypoint must contain the dispatcher before routing can work. Verify actual trace coverage after startup; no trust prompt should be answered automatically.

The instrumented executable can run `--observe-status 120` without creating panels or restarting the installed app. This exercises the same `StatusStore` refresh code in a separate process; its rows carry `reader_mode: headless`. They establish that reader's timings and model decisions, not the running app's UI paint or main-thread responsiveness. Normal app traces carry `reader_mode: app`. Preserve this distinction when interpreting coverage.

## Capture one session

Obtain the exact session ID from the corresponding status filename: `claude-<session>.json` or `codex-<session>.json`. Terminal IDs and session IDs are different. Record the agent/version, whether the session is fresh or resumed, and which display is wrong. Keep the other sessions running to retain concurrency.

Start a bounded capture in a separate terminal before reproducing the issue:

```sh
python3 scripts/diagnostics.py watch claude SESSION_ID --seconds 120
```

Use `codex` for a Codex capture. The observer reads existing status and transcript files every 100 ms, emits only changes/metadata, and stops after the requested duration (1–600 seconds). It reads at most 1 MiB per pass, records oversized/malformed/truncated rows as gaps, and skips Claude sidechain rows. Its initial 64 KiB transcript tail is marked `baseline_tail`; later rows are marked `live_append`. Source timestamps identify when the agent wrote an event; trace timestamps identify when the observer read it. Transcript flush delay remains part of that gap.

Optional markers name observations without storing free text:

```sh
python3 scripts/diagnostics.py mark claude SESSION_ID question_visible
python3 scripts/diagnostics.py mark claude SESSION_ID answer_submitted
python3 scripts/diagnostics.py mark claude SESSION_ID stale_seen
python3 scripts/diagnostics.py sample claude SESSION_ID
python3 scripts/diagnostics.py mark claude SESSION_ID correct_seen
python3 scripts/diagnostics.py report --agent claude --session SESSION_ID --tail 200
```

`sample` performs one read-only Ghostty query and compares the status file with the tab glyph. It never changes a title, focuses a tab, or sends input. A failed query exits 2 and records a failure category. `title.applied` means Ghostty accepted the title action, not that pixels were verified; use `sample` or a timed visual observation to confirm the shown glyph. `sidebar.row` records the model published to SwiftUI, not a measured paint completion. Markers are manually timed and should not be used to claim subsecond latency.

## Separate reproduction cases

For Claude, capture AskUserQuestion answered, permission approval, permission denial, Esc/interrupt, and a new prompt after idle. Distinguish a tool question from a question written in ordinary assistant text. Include a main-agent request and a subagent permission request. Preserve other pending requests when interpreting a completion.

For Codex, capture a blocking question, an asynchronous question while work continues, a permission request, turn completion and cancellation. Include main/subagent activity and fresh/resumed threads. An asynchronous question can remain unanswered while the agent works; tool completion alone is not proof that the user answered. Match call IDs and event source timestamps rather than assuming Claude's event lifecycle applies.

For each case, record expected behavior and compare both the tab title and sidebar against a successful case. A capture is incomplete if the relevant producers are absent, the source fingerprint changes, a gap/drop is reported, or the failure cannot be tied to an exact session.

## Reading the evidence

| Events | What they establish |
|---|---|
| `observer.transcript` | Agent-specific event category, source timestamp and hashed call/tool identity, excluding content |
| `hook.received`, `hook.transition`, `hook.pending_before` | Hook receipt, old/new state, pending-request fingerprints and count |
| `hook.git.*`, `lock.acquired`, `lock.timeout`, `probe.lock_wait`, `probe.lock_acquired`, `probe.lock_timeout` | Time spent on metadata, status/tab locks and the shared title-probe lock |
| `status.written`, `worker.spawned`, `worker.apply.*` | Status commit, worker spawn and worker execution; hook/worker share `trace_id` |
| `ghostty.call_*`, `probe.*`, `title.inspect`, `title.applied` | Ghostty duration/failure, resolution and requested vs previously shown state |
| `sidebar.refresh_*`, `sidebar.ghostty_*`, `sidebar.status_read` | Refresh scheduling and whether Ghostty delayed status reads |
| `evidence.*`, `sidebar.reconcile`, `sidebar.row`, `sidebar.published` | Evidence timestamps, hook/evidence decision and published model |
| `observer.tab`, `capture.marker` | Read-back tab glyph or manual visual/input observation |

On `hook.received`, `request_id` hashes the incoming actor/call key. Calls with an ID use that stable ID; calls without one use a tool/input fallback. A PermissionRequest without an ID may resolve to an earlier registered call, so its incoming key can differ from the actual `pending_keys`. Logging records these decisions without changing them. `actor_id` distinguishes main/subagent events. Session and terminal fingerprints join Python, observer and sidebar rows. `reported_ms` and `evidence_ms` expose timestamp precedence. Duration fields use monotonic clocks; timestamps use wall clocks and may be affected by clock adjustments.

Use these stages to distinguish a late source event, a missing/mismatched completion, a lock timeout, slow Ghostty access, failed terminal resolution, a failed title action, and a sidebar decision that retained old state. Investigate the demonstrated branch before changing its behavior.

## Privacy and limits

Trace fields are allowlisted. Prompts, answers, command bodies, tool outputs, titles, working directories, transcript paths, exception messages and AppleScript bodies are excluded. IDs, tool names and pending keys are SHA-256 fingerprints truncated to 16 hexadecimal characters; traces are still private operational evidence. Directories use mode 0700 and logs use 0600. Log/lock symlinks are rejected.

Each producer retains one active log and one rotated backup, each approximately 2 MiB (one record can exceed the threshold). Writers use nonblocking locks and fail open. Python reports failures dropped earlier in the same process as `dropped_before` on its next successful row; an exiting process may never report its drops. Missing rows are not proof an operation did not occur. The observer is bounded but filesystem reads can still be slow. Diagnostics add filesystem and hashing work, so compare observed overhead before attributing small delays to the agent.

Disabling diagnostics retains existing files for analysis. Export or remove only the diagnostic directory when the investigation ends; do not remove status files or replay captured events into live hooks.
