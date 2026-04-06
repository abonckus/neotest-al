# Changelog

## [1.0.0] - 2026-04-06

Initial release.

### Features

- **LSP discovery** — queries `al/discoverTests` from the AL language server; cache invalidated automatically on `al/projectsLoadedNotification`
- **Treesitter discovery** — parses AL test files locally via treesitter; works offline without LSP
- **LSP runner** — executes tests via `al/runTests`; reads launch configuration from `.vscode/launch.json`; handles publish, dirty-state tracking, auth failures (401), and compiler diagnostics
- **Pluggable architecture** — discovery and runner are independently swappable via the adapter config
- **Windows path normalization** — handles mixed separators and case-insensitive path comparisons throughout
- **ANSI-colored output** — build log and test results rendered with color in the neotest output panel
