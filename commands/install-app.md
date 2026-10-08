---
description: Build the Ghostty Sidebar app from this plugin's source and install it in ~/Applications
---

Build and install the sidebar app. It needs Xcode's command-line tools (`xcode-select --install`).

Run:

```bash
"${CLAUDE_PLUGIN_ROOT}/app/build.sh"
```

Report the last lines of the output. On success, tell the user:
- the app is at `~/Applications/Ghostty Sidebar.app` and has been started (icon in the menu bar);
- the first click on a row asks for permission to control Ghostty (Automation);
- attaching the panel to a Ghostty window needs Accessibility permission, asked by "Attach to Front Window", "One Sidebar per Window" or "Keep Ghostty Windows Beside Sidebar" in the menu-bar menu;
- the grants survive rebuilds; if the sidebar shows an Accessibility warning, remove Ghostty Sidebar with − under System Settings → Privacy & Security → Accessibility and choose "Attach to Front Window" again.

If `swift` is missing, tell the user to run `xcode-select --install` and retry.
