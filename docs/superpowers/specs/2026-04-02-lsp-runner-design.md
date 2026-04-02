# LSP Runner Design

**Date:** 2026-04-02  
**Status:** Approved

## Overview

Implement `runner/lsp` — the AL Language Server Protocol test runner for neotest-al. Replaces the current placeholder in `runner/lsp.lua` with a full implementation that sends `al/runTests`, streams results via LSP notifications, and maps them to neotest's result format.

---

## Module Structure

```
lua/neotest-al/runner/
├── lsp/
│   ├── init.lua        — runner interface: build_spec(), results()
│   ├── launch.lua      — reads .vscode/launch.json, vim.ui.select picker
│   ├── dirty.lua       — BufWritePost watcher, per-workspace dirty flag
│   ├── run.lua         — sends al/runTests, wires notifications, writes temp file
│   └── diagnostics.lua — parses compiler errors, sets vim.diagnostic entries
└── lsp.lua             — backward-compat shim: re-exports runner/lsp/init
```

---

## Data Flow

```
build_spec(args, discovery)
  → launch.lua: read + select launch config
  → dirty.lua:  is_dirty(workspace)? → determine SkipPublish
  → run.lua:    register notification handlers, send al/runTests,
                accumulate results, write temp file on al/testRunComplete
  → return spec { results_path = "/tmp/neotest-al-XXXX.json" }

results(spec, result, tree)
  → read temp file (JSON)
  → diagnostics.lua: set vim diagnostics for compiler errors
  → map (codeunit_id, test_name) → neotest position ID → result table
```

---

## Section 1: Launch Config (`launch.lua`)

### Runner Config Options

```lua
require("neotest-al.runner.lsp").new({
  launch_json_path = nil,  -- override path; absolute or relative to workspace root
                           -- default: <workspace_root>/.vscode/launch.json
})
```

### Workspace Root Resolution

Walk up the directory tree from the test file path until `app.json` is found — same root marker used by `adapter.lua`.

### launch.json Path Resolution

1. `launch_json_path` from runner config (if set)
2. `<workspace_root>/.vscode/launch.json` (default)

### Config Selection

- Filter entries where `type == "al"` and `request == "launch"`
- 0 matching configs → error notification, abort run
- 1 matching config → use directly, no picker
- 2+ matching configs → `vim.ui.select()` showing config names; block until user picks

### Caching

The selected config is cached per workspace root for the session. The picker only appears once per workspace, not before every run. The cache is invalidated when `launch.json` changes on disk (via `BufWritePost` on the launch.json file).

---

## Section 2: Dirty Tracking (`dirty.lua`)

### State

```lua
-- keyed by normalized workspace root path
dirty = {
  ["c:/path/to/workspace"] = true,
}
```

### Marking Dirty

A single global autocmd on `BufWritePost` for `*.al` files, registered once at module load. When fired, walk up from the saved file's path to find the workspace root (`app.json` marker), then set `dirty[root] = true`.

### Marking Clean

Called by `run.lua` after a successful publish — i.e. `al/runTests` completes without build errors and `SkipPublish` was `false`.

### `is_dirty(workspace_root)`

Returns `true` if:
- `dirty[workspace_root]` is set, **or**
- No successful publish has ever occurred for this workspace (first run is always dirty)

### Effect on SkipPublish

| Condition | SkipPublish |
|-----------|-------------|
| `is_dirty()` | `false` — build and publish |
| `not is_dirty()` | `true` — skip publish |

After a successful publish with `SkipPublish: false`, clear the dirty flag.

---

## Section 3: Test Run & Result Writing (`run.lua`)

### Temp File Format

Written atomically as a single JSON file when `al/testRunComplete` fires:

```json
{
  "build_log": ["[2026-04-02 ...] Preparing to build...", "..."],
  "build_errors": [
    {
      "file": "c:/path/to/Foo.al",
      "line": 12,
      "col": 4,
      "severity": "error",
      "code": "AL0001",
      "message": "Symbol 'Foo' is not found"
    }
  ],
  "tests": [
    {
      "name": "MyTest_WhenCondition_ShouldDoX",
      "codeunit_id": 69001,
      "status": 0,
      "message": "",
      "duration": 950
    }
  ]
}
```

### Notification Lifecycle

1. Register handlers for `al/testExecutionMessage`, `al/testMethodStart`, `al/testMethodFinish`, `al/testRunComplete` on the LSP client **before** sending `al/runTests`
2. Accumulate build log lines and parsed compiler errors in memory as `al/testExecutionMessage` arrives
3. On `al/testMethodFinish` with non-empty `name` — record test result
4. On `al/testRunComplete` — write temp file, deregister handlers, mark workspace clean if no build errors

### Authentication Error Detection

Scan each `al/testExecutionMessage` line for (case-insensitive): `"Unauthorized"`, `"401"`, `"authentication failed"`. If matched, set a flag so the final write includes the auth failure context. Fire a Neovim notification: `"AL authentication failed — run :AL authenticate"`.

### `build_spec` Return Shape

```lua
{
  results_path = vim.fn.tempname() .. ".json",
  -- no `command` field — execution is driven via LSP, not a subprocess
}
```

`build_spec` is called by neotest in a coroutine context. It blocks by polling a `done` flag with `vim.wait(timeout, function() return done end, 20)` — the same pattern used in `discovery/lsp.lua`. When `al/testRunComplete` fires, the notification handler sets `done = true`, `vim.wait` returns, and `build_spec` returns the spec with the already-written results file. This means `results_path` is guaranteed to exist when `results()` is called.

---

## Section 4: Diagnostics & Result Mapping

### Compiler Error Parsing (`diagnostics.lua`)

AL compiler errors in `al/testExecutionMessage` follow:
```
c:/path/to/Foo.al(12,4): error AL0001: Symbol 'Foo' is not found
```

Lua pattern: `^(.+)%((%d+),(%d+)%):%s*(error|warning|info)%s+(%w+):%s+(.+)$`

- Errors and warnings are captured; informational messages are ignored for diagnostics
- Grouped by file path and set via `vim.diagnostic.set()` using namespace `neotest-al-build`
- Diagnostics are cleared at the start of each run and repopulated after

### Result Mapping (`init.lua` → `results()`)

neotest passes a `tree` to `results()`. Iterate `tree:iter_nodes()` and for each node where `node:data().type == "test"`, extract the position ID. The position ID encodes the file path, codeunit name, and test name (via `base.position_id`). Match each `al/testMethodFinish` result to a tree node by comparing `codeunit_id` (looked up from the discovery cache keyed by file path) and `name` (test method name). This avoids needing to reconstruct position IDs from scratch.

| `al/testMethodFinish` status | neotest status |
|------------------------------|----------------|
| `0` | `"passed"` |
| `1` | `"failed"` |
| `2` | `"skipped"` |

- `message` from `al/testMethodFinish` → neotest `short` (shown inline)
- Full build log → neotest `output` (shown in output panel)
- `duration` (ms) → neotest `duration`

### Build Failure with No Tests

If `build_errors` is non-empty and `tests` is empty, all selected tests are marked `"failed"` with `short = "Build failed — see diagnostics"`.

---

## Key Constraints

- `launch.lua`, `dirty.lua`, `run.lua`, and `diagnostics.lua` have no dependencies on each other — only `init.lua` orchestrates them
- No dependency on al.nvim — launch.json is read independently
- The `BufWritePost` autocmd and notification handlers are registered once at module load, not per run
- The `lsp.lua` shim maintains backward compatibility with existing adapter configs that reference `runner/lsp`
