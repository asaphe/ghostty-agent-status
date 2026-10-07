# ghostty-agent-status

See at a glance which of your Claude Code and Codex sessions are **working**, **waiting for you**, or **idle**, across every Ghostty tab.

Two parts, usable separately:

- **The plugin (hooks).** Every session event updates a small status file and the tab's title: ⏳ working, ✋ waiting for you, 💤 idle, 🏁 done. A colored square marks the repo and branch. This alone makes Ghostty's tab bar a status board.
- **The sidebar app.** A floating "Session Status" panel, grouped by window in tab order, shown while Ghostty is in front. Click a row to jump to its tab.

Requirements: macOS 14+, [Ghostty](https://ghostty.org) 1.3+ (it uses Ghostty's AppleScript support), Python 3.9+ (the macOS system Python is fine). The app also needs Xcode's command-line tools to build.

## Install

### With an AI agent (recommended)

Paste this into Claude Code or Codex, running in Ghostty:

```
Set up https://github.com/asaphe/ghostty-agent-status for me by following its SETUP.md step by step.
```

[SETUP.md](SETUP.md) is written for agents. It runs preflight checks, asks which parts you want, installs them, verifies each step, and stops for anything only you can do (macOS permission dialogs, trusting the Codex hook).

### By hand

```bash
git clone https://github.com/asaphe/ghostty-agent-status ~/.local/share/ghostty-agent-status

# Claude Code plugin: tab status, the core
claude plugin marketplace add asaphe/ghostty-agent-status
claude plugin install ghostty-agent-status@ghostty-agent-status

# Sidebar app (optional; needs Xcode command-line tools): builds, installs and starts it
~/.local/share/ghostty-agent-status/app/build.sh

# Codex (optional): adds the hook to ~/.codex/hooks.json, keeping your other hooks and a backup
python3 ~/.local/share/ghostty-agent-status/codex/install.py
```

Then start a new agent session in Ghostty: its tab title gets a status glyph on the first prompt.
- **Codex:** trust the new hook in the TUI's hook review first.
- **Sidebar app:** the first click on a row asks to let the app control Ghostty. The optional **Keep Ghostty Windows Beside Sidebar** menu item asks for Accessibility permission. The app is built locally, so it needs no Developer ID and macOS doesn't quarantine it. Each rebuild asks for those permissions again.

Inside Claude Code, `/ghostty-agent-status:install-app` builds the app from the installed plugin instead of a clone.

Updating, uninstalling and troubleshooting: [SETUP.md](SETUP.md#updating).

## How the state is decided

| Signal | State |
|---|---|
| `UserPromptSubmit`, the main agent's tool events | working |
| `PermissionRequest` (tool permission, AskUserQuestion, plan approval), `Notification` `permission_prompt`/`elicitation_dialog`, a question tool | waiting |
| `Stop`, `StopFailure`, `SessionStart`, `Notification` `idle_prompt` | idle (`Stop`'s running `background_tasks` become the row's message) |
| `SessionEnd` | done |

**Claude Code fires no hook when you deny a permission, press Esc, or decline a plan.** The sidebar ends those turns from the session transcript instead: the `[Request interrupted by user` row or the `turn_duration` row that Claude Code writes. Tab titles still show the last hook state until the next event. Codex records interrupts as `turn_aborted` in its rollout, which the sidebar reads the same way.

Subagent and hook-helper tool events carry an `agent_id` and never flip the main session's state; a subagent's permission prompt still shows as waiting, because it waits for you. Codex threads that have no tab of their own (`codex exec`, IDE threads, subagents) are not tracked.

## Finding a session's tab

Ghostty 1.3 gives a process no way to learn which terminal it runs in. The hook writes a one-off OSC 2 title to the agent's tty, reads all terminal titles over AppleScript, and restores the previous title. A tab the probe has not matched yet appears under **Tab not identified yet**, and clicking it only activates Ghostty.

## Status files

One JSON file per session at `$GHOSTTY_AGENT_STATUS_DIR/status/<agent>-<session_id>.json`. The default directory is `~/.local/state/ghostty-agent-status`. Each file is written to a temp file and renamed into place. Other tools can read them:

| Field | Meaning |
|---|---|
| `agent` | `claude` or `codex` |
| `session_id` | the agent's session ID |
| `state` | `working`, `waiting`, `idle` or `done` |
| `title`, `cwd`, `repo`, `branch` | what the row shows |
| `color` | `#rrggbb` derived from `repo:branch` |
| `ghostty_terminal_id` | the Ghostty terminal, or `null` until found |
| `pid` | the agent process; the sidebar ignores records whose process has exited |
| `updated_at`, `message` | ISO-8601 UTC time; short text such as what the session waits on |

Files of sessions that ended more than a day ago are removed.

### Labeling a tab

A script can give a tab a label, and optionally a milestone, that survives status updates:

```bash
python3 scripts/terminal_status.py label <ghostty-terminal-id> "Release prep" "tests green"
```

## Development

```bash
/usr/bin/python3 -m unittest discover -s scripts/tests
bash app/test.sh
app/.build/release/GhosttySidebar --snapshot   # after swift build: print the reconciled rows as JSON
```

## License

MIT
