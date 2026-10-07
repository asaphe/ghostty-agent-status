# Setup guide (for AI coding agents)

You are setting up ghostty-agent-status for the user on their Mac. Follow the steps in order. Each step has a **check**; do not move on until it passes. Stop and ask the user wherever a step says **ASK**. Never answer a macOS permission dialog, a Codex hook-trust review, or a Claude Code trust prompt on the user's behalf: those are theirs.

Humans: the same steps work by hand. The [README](README.md#install) has the short version.

## 0. Preflight

Run each, and stop with the failing line if any check fails:

| Check | Command | Pass when |
|---|---|---|
| macOS 14+ | `sw_vers -productVersion` | major version ≥ 14 |
| Ghostty 1.3+ | `/Applications/Ghostty.app/Contents/MacOS/ghostty +version` | first line shows 1.3 or later |
| Ghostty AppleScript enabled | `osascript -e 'tell application "Ghostty" to count windows'` | prints a number. An error means `macos-applescript = false` is set in the Ghostty config, or the user has not yet allowed the terminal to control Ghostty. |
| Python 3.9+ | `python3 -c 'import sys; print(sys.version_info >= (3, 9))'` | `True` |
| Build tools (app only) | `xcode-select -p && swift --version` | both succeed. Otherwise the user runs `xcode-select --install`. |

The first `osascript` call can raise a macOS "wants to control Ghostty" dialog. Tell the user to click **OK**, then re-run the check.

**ASK** which parts the user wants: the Claude Code plugin (tab status, the core), the sidebar app, Codex support. Default: all that apply to the agents they use.

## 1. Clone the repo

Both the app build and the Codex hooks run from this clone, so it must stay in place:

```bash
git clone https://github.com/asaphe/ghostty-agent-status ~/.local/share/ghostty-agent-status
```

If the directory exists, run `git -C ~/.local/share/ghostty-agent-status pull --ff-only` instead.
**Check:** `test -x ~/.local/share/ghostty-agent-status/scripts/ghostty-status.py && echo ok` prints `ok`.

## 2. Claude Code plugin

```bash
claude plugin marketplace add asaphe/ghostty-agent-status
claude plugin install ghostty-agent-status@ghostty-agent-status
```

**Check:** `claude plugin list` lists `ghostty-agent-status`.

**Conflicts:** look in `~/.claude/settings.json` for other hooks that set the terminal or tab title on every event. Two writers overwrite each other's tab title. **ASK** before changing anything there.

Hooks load when a session starts. Tell the user: **open a new Ghostty tab, start `claude`, and send any prompt.** Then:
**Check:** `ls ~/.local/state/ghostty-agent-status/status/` shows a `claude-<session-id>.json` file. Within a few seconds that tab's title starts with ⏳ while Claude works, then 💤 when it finishes.

## 3. Sidebar app (optional)

```bash
~/.local/share/ghostty-agent-status/app/build.sh
```

The script builds the app (about a minute the first time), installs `~/Applications/Ghostty Sidebar.app`, and starts it. The app's icon appears in the menu bar, and the panel shows while Ghostty is in front.

**Check:** `~/Applications/Ghostty\ Sidebar.app/Contents/MacOS/GhosttySidebar --snapshot` prints a JSON array with one row per open Ghostty terminal. The Claude session from step 2 should show its state.

Tell the user to expect two permission prompts:
- **Automation:** the first click on a row asks to let the app control Ghostty. It is needed to jump to the tab.
- **Accessibility:** asked only if they turn on **Keep Ghostty Windows Beside Sidebar** in the menu-bar menu.

Each rebuild changes the app's ad-hoc signature, so macOS asks again after an update.

**Optional:** to start the app at login, the user adds it under System Settings → General → Login Items.

## 4. Codex (optional)

```bash
python3 ~/.local/share/ghostty-agent-status/codex/install.py --dry-run   # show the change
python3 ~/.local/share/ghostty-agent-status/codex/install.py
```

The installer adds the hook to `~/.codex/hooks.json` (or `$CODEX_HOME/hooks.json`) on 8 events. It keeps every existing hook and backs the file up as `hooks.json.bak-<timestamp>`. Running it twice changes nothing.

**Check:** the output says `8 event(s) added` (or `0` if it was already installed).

Tell the user: **in a new Codex session, open the hook review and trust the new hook** (`t` trusts all). Codex skips untrusted hooks. Older threads keep the hook list they started with; `codex resume <id>` picks up the new one.

**Check:** after a prompt in that Codex tab, `ls ~/.local/state/ghostty-agent-status/status/` shows a `codex-<thread-id>.json` file.

## 5. Report to the user

Summarize which parts are installed, every check result, and what is still waiting on them: permission dialogs, the hook trust in Codex, opening a new session.

## Updating

```bash
claude plugin update ghostty-agent-status
git -C ~/.local/share/ghostty-agent-status pull --ff-only
~/.local/share/ghostty-agent-status/app/build.sh   # only if the app is installed
```

## Uninstalling

```bash
claude plugin uninstall ghostty-agent-status
claude plugin marketplace remove ghostty-agent-status
python3 ~/.local/share/ghostty-agent-status/codex/install.py --uninstall
```

Then:
- quit the app from its menu-bar icon, and delete `~/Applications/Ghostty Sidebar.app`;
- delete `~/.local/state/ghostty-agent-status` and `~/.local/share/ghostty-agent-status`. **ASK** before deleting anything.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| No status file appears | The session started before the plugin was installed, or outside Ghostty (`echo $TERM_PROGRAM` must print `ghostty`). Start a new session in Ghostty. |
| Row stuck under "Tab not identified yet" | The tab could not be matched yet. It resolves on the session's next event. Matching works by briefly retitling the tab, so it can miss while the agent redraws its title. |
| Sidebar says "Ghostty refresh failed" | AppleScript to Ghostty was denied. Re-allow it in System Settings → Privacy & Security → Automation. |
| Hook timeouts in the transcript | Python start-up is slow. The hooks run the first `python3` on `PATH`, and a version-manager shim (pyenv, asdf) can add about a second per event on a busy machine. Set `GHOSTTY_AGENT_STATUS_PYTHON` to a direct interpreter path in the `env` block of `~/.claude/settings.json`, e.g. `"GHOSTTY_AGENT_STATUS_PYTHON": "/usr/bin/python3"`, then start a new session. |
| Codex rows never appear | The hook isn't trusted yet in the Codex TUI, or the thread predates the install. |
