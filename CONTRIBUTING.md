# Contributing to ghostty-agent-status

Thanks for considering a contribution.

## Developer Certificate of Origin (DCO)

Contributions require a sign-off, not a signed CLA. Add `-s` to your commits:

```sh
git commit -s -m "fix: ..."
```

This adds a `Signed-off-by` trailer certifying you have the right to submit
the change under this project's license (MIT). See
[developercertificate.org](https://developercertificate.org/) for the exact
text you're certifying.

## Before opening a PR

```sh
/usr/bin/python3 -m unittest discover -s scripts/tests   # Python 3.9, the oldest supported
bash app/test.sh                                        # Swift reconciliation tests
swift build -c release --package-path app
```

## Versioning

`claude plugin update` compares the `version` in `.claude-plugin/plugin.json`, so a change
that does not bump it never reaches installed copies. Bump it in every PR that changes the
plugin (hooks, scripts, commands): patch for fixes, minor for new behaviour.

## Changing how a state is decided

Agent CLIs change their events and transcript formats between releases. A change
to the state logic needs a test that reproduces the case, and the PR description
should name the agent version you observed it on and how: a logged hook payload
or a transcript row. Claude Code fires no hook when a prompt is denied, Esc is
pressed or a plan is declined, so those cases come from the transcript and are
the most likely to drift.

## Reporting a security issue

Report anything that lets hook input reach a shell or AppleScript privately, as
described in [SECURITY.md](SECURITY.md), rather than in a public issue.
