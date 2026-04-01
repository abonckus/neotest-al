# neotest-al

A [neotest](https://github.com/nvim-neotest/neotest) adapter for the AL language (Microsoft Dynamics 365 Business Central).

## Requirements

- Neovim >= 0.10
- [neotest](https://github.com/nvim-neotest/neotest)
- [nvim-nio](https://github.com/nvim-neotest/nvim-nio)
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) with the AL grammar installed
- For LSP discovery: an active `al_ls` language server (provided by [al.nvim](https://github.com/your-org/al.nvim) or manual `vim.lsp.config` setup)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "your-org/neotest-al",
    dependencies = {
        "nvim-neotest/neotest",
        "nvim-neotest/nvim-nio",
    },
}
```

## Setup

### Zero config (recommended)

Defaults to LSP discovery and the LSP runner placeholder. Tests are discoverable as soon as `al_ls` attaches.

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
            discovery = require("neotest-al.discovery.lsp"),   -- default
            runner    = require("my-company.al-runner"),        -- custom runner
        }),
    },
})
```

## Discovery Options

| Module | Description | Requires |
|--------|-------------|----------|
| `neotest-al.discovery.lsp` | Queries `al/discoverTests` from the AL language server. Accurate, always in sync with the server. | `al_ls` attached |
| `neotest-al.discovery.treesitter` | Parses test files locally via treesitter. Works offline; no LSP required. | AL treesitter grammar |

To use treesitter discovery:

```lua
require("neotest-al")({
    discovery = require("neotest-al.discovery.treesitter"),
})
```

## Runner Options

| Module | Description |
|--------|-------------|
| `neotest-al.runner.lsp` | Placeholder. Shows a warning and skips execution. LSP-based running (`al/runTests`) is not yet implemented. |
| Custom | Any table implementing the `Runner` interface (see below). |

## Writing a Custom Runner

A runner must be a table with the following fields:

```lua
---@class neotest-al.Runner
---@field name string
---@field build_spec fun(args: neotest.RunArgs, discovery: neotest-al.Discovery): neotest.RunSpec|nil
---@field results   fun(spec: neotest.RunSpec, result: neotest.StrategyResult, tree: neotest.Tree): table<string, neotest.Result>
```

`build_spec` receives the active `discovery` module as its second argument so the runner can invalidate the test cache after a build:

```lua
function M.build_spec(args, discovery)
    -- ... build your RunSpec ...

    -- After publishing the app, clear the LSP discovery cache so
    -- neotest re-discovers tests from the updated server state.
    local client = get_al_client()
    if client then
        discovery.invalidate(client.id)
    end

    return run_spec
end
```

## LSP Discovery Notes

- The cache is populated on the first `discover_positions` call per workspace and reused for all subsequent files in that workspace until invalidated.
- The cache is invalidated automatically when the AL server fires `al/projectsLoadedNotification` (which happens after a publish/build cycle).
- You can also invalidate manually: `require("neotest-al.discovery.lsp").invalidate()`.
- If [al.nvim](https://github.com/your-org/al.nvim) is installed, neotest-al reuses its notification handler infrastructure; otherwise it registers a global `vim.lsp.handlers` entry directly.
