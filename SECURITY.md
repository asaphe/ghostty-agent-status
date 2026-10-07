# Security policy

## Reporting a vulnerability

Report privately through GitHub Security Advisories:
**[Report a vulnerability](https://github.com/asaphe/ghostty-agent-status/security/advisories/new)**

Please do not open a public issue for a security report.

This is a solo-maintained project. Expect an acknowledgement within a week and a
fix or an explicit decision not to fix within a month. There is no paid support
and no SLA.

## Supported versions

Pre-1.0. Only the current `main` is supported.

## What counts as a vulnerability here

The hooks run on every Claude Code and Codex event, with your user's rights, and
write to your terminal. In scope:

- Hook input (a session ID, cwd, tool input or title) that reaches a shell, an
  AppleScript source string or a file path unescaped.
- A status, label or lock file written somewhere other than the state directory,
  or readable by another user.
- Anything that makes the sidebar app run a command, or focus or type into a
  terminal, other than the one row the user clicked.

Out of scope:

- Wrong status (working shown as idle, and the like). That is a bug; open an issue.
- Findings that require an attacker who can already write to your hook scripts,
  your Claude Code or Codex settings, or the state directory.
