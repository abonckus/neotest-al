# neotest-al: Pluggable Discovery & Runner Design

**Date:** 2026-04-02  
**Status:** Approved

---

## Summary

Refactor `neotest-al` to separate test discovery from test running, expose both as pluggable interfaces with typed contracts, and ship a new LSP-based discovery module (`al/discoverTests`) alongside the existing treesitter discovery. The old monolithic adapter (treesitter + `altest.exe` CLI) moves to a private Continia repository that implements the public `Runner` interface. A placeholder LSP runner is included to define the interface for future implementation.

---

## Goals

- Clean public OSS package — no company-specific code (API keys, internal CLI paths)
- LSP-based discovery as default, treesitter as offline fallback
- Typed contracts so third-party runners know exactly what to implement
- Zero-config default: `require("neotest-al")` works out of the box with LSP discovery
- Cache invalidation tied to build lifecycle, not arbitrary timers

---

## File Structure

```
neotest-al/
├── README.md
├── lua/neotest-al/
│   ├── init.lua                    -- factory (unchanged shape)
│   ├── adapter.lua                 -- orchestrator; validates + wires discovery + runner
│   ├── base.lua                    -- is_test_file (unchanged)
│   ├── discovery/
│   │   ├── init.lua               -- @class neotest-al.Discovery typedef
│   │   ├── treesitter.lua         -- treesitter-based discovery (extracted from old adapter.lua)
│   │   └── lsp.lua                -- al/discoverTests-based discovery (new)
│   └── runner/
│       ├── init.lua               -- @class neotest-al.Runner typedef
│       └── lsp.lua                -- placeholder LSP runner (al/runTests — not yet implemented)
└── docs/
    └── superpowers/specs/
        └── 2026-04-02-pluggable-discovery-runner-design.md
```

**What is removed from this repo:**
- `build_spec` using `altest.exe`
- `results.lua` XML parser
- The hardcoded API key

These move to a private Continia repository that implements the `Runner` interface.

---

## Interface Contracts

### `neotest-al.Discovery`

```lua
---@class neotest-al.Discovery
---@field name string
---@field discover_positions fun(path: string): neotest.Tree|nil   -- async (nio coroutine)
---@field invalidate fun(client_id?: integer): nil                  -- nil clears all
```

- `discover_positions` is called by neotest per test file inside a nio coroutine. Returns `nil` if the file has no tests or the backend is not ready.
- `invalidate` is called by the runner after a build. Pass `client_id` to clear only that workspace's cache; pass `nil` to wipe everything.

### `neotest-al.Runner`

```lua
---@class neotest-al.Runner
---@field name string
---@field build_spec fun(args: neotest.RunArgs, discovery: neotest-al.Discovery): neotest.RunSpec|nil
---@field results   fun(spec: neotest.RunSpec, result: neotest.StrategyResult, tree: neotest.Tree): table<string, neotest.Result>
```

- `build_spec` receives the `discovery` module so it can call `discovery.invalidate(client_id)` after its build/publish step — no global state needed.
- `results` follows the standard neotest contract.

### Adapter validation

`adapter.lua` asserts both modules at init time:

```lua
assert(type(discovery.discover_positions) == "function",
    "neotest-al: discovery must implement discover_positions(path)")
assert(type(runner.build_spec) == "function",
    "neotest-al: runner must implement build_spec(args, discovery)")
assert(type(runner.results) == "function",
    "neotest-al: runner must implement results(spec, result, tree)")
```

Fails immediately with a clear message rather than a nil-index error at runtime.

---

## Defaults

```lua
-- zero config
require("neotest-al")

-- equivalent explicit config
require("neotest-al")({
    discovery = require("neotest-al.discovery.lsp"),
    runner    = require("neotest-al.runner.lsp"),
})
```

- Default discovery: `lsp` — requires `al_ls` to be attached
- Default runner: `lsp` placeholder — warns and returns `nil` from `build_spec` until implemented

---

## LSP Discovery Internals (`discovery/lsp.lua`)

### Client resolution (soft dep on al.nvim)

```lua
local function find_client(path)
    local ok, Lsp = pcall(require, "al.lsp")
    if ok then
        return Lsp.get_client_for_buf(vim.fn.bufnr(path))
    end
    -- fallback: raw vim.lsp scan by root_dir prefix
    local norm = vim.fs.normalize(path)
    for _, client in ipairs(vim.lsp.get_clients({ name = "al_ls" })) do
        local root = vim.fs.normalize(client.root_dir or "")
        if norm:sub(1, #root) == root then return client end
    end
end
```

If al.nvim is installed the existing client is reused; otherwise a raw `vim.lsp` scan finds the `al_ls` client whose `root_dir` is a prefix of the file path.

### Cache shape

```
cache = {
    [client_id] = {
        ["/abs/path/to/File.al"] = {
            codeunit_name = string,
            codeunit_id   = integer,
            tests         = { LSPTestItem... }
        },
        ...
    }
}
```

One cache entry per LSP client (workspace). Keyed by absolute normalized file path.

### Population

On the first `discover_positions` call for a `client_id` with no cache entry:
1. Send `al/discoverTests {}` via `nio.wrap` (yields inside the coroutine)
2. Walk the response tree (app → codeunit → test) and index by `uri_to_fname(test.location.source)`
3. Store under `cache[client_id]`

Subsequent calls for any file in the same workspace are served from cache with no LSP round-trip.

### Invalidation triggers

1. **Runner calls `discovery.invalidate(client_id)`** after its build/publish step
2. **`al/projectsLoadedNotification`** — registered once when the first client attaches; clears `cache[client_id]` automatically. Uses `al.lsp.set_handler` if al.nvim is present, otherwise patches `vim.lsp.handlers`.

### `discover_positions` flow

```
discover_positions(path)
  └─ find_client(path)         -- nil → return nil
  └─ cache hit?
       miss → fetch al/discoverTests, populate cache
       hit  → use cache
  └─ cache[client_id][norm_path]?
       nil → return nil
       hit → build pos_list:
               { type="file",  range={0, 0, last_line, 0} }
               { type="test",  range from LSP location.range (already 0-based) }
             → Tree.from_list(pos_list)
```

---

## LSP Runner Placeholder (`runner/lsp.lua`)

Implements the full `Runner` interface. `build_spec` returns `nil` (neotest skips execution cleanly) and emits a visible warning:

```lua
function M.build_spec(args, discovery)
    vim.notify(
        "neotest-al: LSP runner is not yet implemented. "
        .. "Configure a runner in your neotest-al setup.",
        vim.log.levels.WARN
    )
    return nil
end
```

The placeholder establishes the correct function signatures and serves as the stub for the future `al/runTests` implementation.

---

## README Sections

1. **Requirements** — Neovim, neotest, treesitter AL grammar, optional al.nvim
2. **Installation** — lazy.nvim snippet
3. **Setup**
   - Zero config
   - Discovery options (`lsp` / `treesitter`)
   - Runner options (`lsp` placeholder / custom)
4. **Writing a custom runner** — interface signatures, how to call `discovery.invalidate()`
5. **LSP discovery notes** — requires `al_ls`, cache invalidation behaviour

---

## Out of Scope

- `al/runTests` LSP runner implementation (future work)
- Test result streaming via `al/testMethodStart` / `al/testMethodFinish`
- Coverage mode (`CoverageMode`)
- The Continia private runner (separate repository)
