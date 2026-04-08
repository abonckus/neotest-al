# neotest-al

A [neotest](https://github.com/nvim-neotest/neotest) adapter for the AL
language (Microsoft Dynamics 365 Business Central).

## Features

- Test discovery via the AL Language Server (`al/discoverTests`) or treesitter
- Test execution via `al/runTests` with `.vscode/launch.json` configuration
- Dirty-state tracking to skip unnecessary publish steps
- Auth failure and compiler diagnostic detection
- ANSI-colored output in the neotest output panel
- Multi-project workspace support (with [al.nvim] and [code-workspace.nvim])

## Requirements

- Neovim >= 0.10
- [neotest](https://github.com/nvim-neotest/neotest)
- [nvim-nio](https://github.com/nvim-neotest/nvim-nio)
- For LSP discovery/runner: an active `al_ls` client (provided by [al.nvim] or
  manual `vim.lsp.config` setup)
- For treesitter discovery:
  [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) with
  the [AL grammar](https://github.com/SShadowS/tree-sitter-al) installed

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "abonckus/neotest-al",
    dependencies = {
        "nvim-neotest/neotest",
        "nvim-neotest/nvim-nio",
    },
}
```

## Setup

### Zero config (recommended)

Defaults to LSP discovery and the LSP runner. Tests appear as soon as `al_ls`
attaches:

```lua
require("neotest").setup({
    adapters = {
        require("neotest-al"),
    },
})
```

### Explicit config

```lua
require("neotest").setup({
    adapters = {
        require("neotest-al")({
            discovery = require("neotest-al.discovery.lsp"),
            runner    = require("neotest-al.runner.lsp").new({
                -- Path to a specific launch.json (default: auto-detected)
                launch_json_path = "/path/to/.vscode/launch.json",
                -- Maximum poll iterations before timing out (default: 15000)
                max_ticks = 15000,
            }),
        }),
    },
})
```

## Discovery

| Module | Description | Requires |
|--------|-------------|----------|
| `neotest-al.discovery.lsp` | Queries `al/discoverTests` from the AL Language Server. Accurate, always in sync. | `al_ls` attached |
| `neotest-al.discovery.treesitter` | Parses test files locally via treesitter. Works offline. | AL treesitter grammar |

### LSP discovery

The default. Cache is populated on the first `discover_positions` call and
invalidated automatically when the server fires `al/projectsLoadedNotification`
(after each build/publish cycle). `is_test_file` performs an O(1) lookup with no
file I/O.

Manual invalidation:

```lua
require("neotest-al.discovery.lsp").invalidate()
```

### Treesitter discovery

```lua
require("neotest-al")({
    discovery = require("neotest-al.discovery.treesitter"),
})
```

Detects codeunits with `Subtype = Test` and procedures annotated with `[Test]`.

## Runner

### LSP runner (default)

Executes tests via `al/runTests`. Works with any discovery module.

Behavior:
- Reads `.vscode/launch.json` from the workspace root; prompts with
  `vim.ui.select` when multiple AL configurations exist
- Polls `al/hasProjectClosureLoadedRequest` before running (matching VS Code)
- Tracks dirty state per workspace to skip unnecessary publishes
- Detects auth failures (HTTP 401) and compiler errors
- Writes colored output to the neotest output panel

### Custom runner

A runner must implement the following interface:

```lua
---@class neotest-al.Runner
---@field name        string
---@field build_spec  fun(args: neotest.RunArgs, discovery: neotest-al.Discovery): neotest.RunSpec|nil
---@field results     fun(spec: neotest.RunSpec, result: neotest.StrategyResult, tree: neotest.Tree): table<string, neotest.Result>
```

`build_spec` receives the active discovery module so the runner can invalidate
the cache after a build:

```lua
function M.build_spec(args, discovery)
    -- ... build your RunSpec ...
    local client = get_al_client()
    if client then
        discovery.invalidate(client.id)
    end
    return run_spec
end
```

## Compatibility

| Discovery | Runner | Notes |
|-----------|--------|-------|
| lsp | lsp | Recommended. Both sides use the AL Language Server. |
| treesitter | lsp | Discovery offline; execution requires `al_ls` and the AL treesitter grammar. |
| lsp | Custom | Custom runner receives LSP-sourced test metadata. |
| treesitter | Custom | Custom runner receives treesitter-sourced test metadata. |

## Multi-project workspaces

When used with [al.nvim]'s multi-project support, neotest-al works
transparently across all projects in the workspace. Test discovery and
execution use the single shared `al_ls` client regardless of which project
folder the test file belongs to.

No additional configuration is needed — neotest-al detects multi-project mode
automatically when `al.multiproject.workspace_root()` is set.

### Custom discovery interface

A custom discovery module must implement:

```lua
---@class neotest-al.Discovery
---@field name               string
---@field is_test_file       fun(path: string): boolean
---@field discover_positions fun(path: string): neotest.Tree|nil
---@field invalidate         fun(client_id?: integer): nil
---@field get_items          fun(path: string): {codeunit_name: string, codeunit_id: integer, tests: table[]}|nil
```

## License

See [LICENSE](LICENSE).

<!-- link references -->
[al.nvim]: https://github.com/abonckus/al.nvim
[code-workspace.nvim]: https://github.com/abonckus/code-workspace.nvim
