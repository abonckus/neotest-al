# LSP Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `runner/lsp` — a fully working AL LSP test runner that sends `al/runTests`, streams results via LSP notifications, and maps them to neotest's result format.

**Architecture:** The runner is split into four focused sub-modules (`launch`, `dirty`, `diagnostics`, `run`) orchestrated by `runner/lsp/init.lua`. `build_spec` blocks in a nio coroutine until `al/testRunComplete` fires, so the results file is fully written before `results()` is ever called. The discovery module is extended with two public methods (`get_items`, `get_client`) that the runner depends on.

**Tech Stack:** Neovim Lua, nvim-nio (`require("nio")`), neotest Tree API, `vim.lsp`, `vim.diagnostic`, `vim.ui.select`, plenary test framework.

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lua/neotest-al/discovery/lsp.lua` | Modify | Add `get_items(path)` and `get_client(path)` public methods |
| `lua/neotest-al/runner/lsp/launch.lua` | Create | Read `.vscode/launch.json`, select config, cache per workspace |
| `lua/neotest-al/runner/lsp/dirty.lua` | Create | Track unsaved AL files since last publish via `BufWritePost` |
| `lua/neotest-al/runner/lsp/diagnostics.lua` | Create | Parse AL compiler error lines, set `vim.diagnostic` entries |
| `lua/neotest-al/runner/lsp/run.lua` | Create | Send `al/runTests`, wire LSP notifications, write temp JSON file |
| `lua/neotest-al/runner/lsp/init.lua` | Create | Orchestrate: `build_spec`, `results`, item collection, id mapping |
| `lua/neotest-al/runner/lsp.lua` | Modify | Replace placeholder with backward-compat shim |
| `tests/neotest-al/discovery/lsp_spec.lua` | Modify | Add tests for `get_items` and `get_client` |
| `tests/neotest-al/runner/lsp/launch_spec.lua` | Create | Unit tests for launch config loading and selection |
| `tests/neotest-al/runner/lsp/dirty_spec.lua` | Create | Unit tests for dirty-flag state machine |
| `tests/neotest-al/runner/lsp/diagnostics_spec.lua` | Create | Unit tests for AL error parsing and diagnostic dispatch |
| `tests/neotest-al/runner/lsp/run_spec.lua` | Create | Unit tests for notification handling and result writing |
| `tests/neotest-al/runner/lsp/init_spec.lua` | Create | Unit tests for build_spec orchestration and results mapping |
| `tests/neotest-al/interfaces_spec.lua` | Modify | Update placeholder tests to match new shim behavior |

---

## Task 1: Extend discovery/lsp.lua

Add `get_items(path)` (returns cached entry for a file) and `get_client(path)` (public alias for `find_client`) so the runner can access raw LSP test items and the active client.

**Files:**
- Modify: `lua/neotest-al/discovery/lsp.lua`
- Modify: `tests/neotest-al/discovery/lsp_spec.lua`

- [ ] **Step 1: Write failing tests for get_items and get_client**

Append to the end of `tests/neotest-al/discovery/lsp_spec.lua`, before the final `end)`:

```lua
    -- ── get_items ─────────────────────────────────────────────────────────────
    describe("get_items", function()
        it("returns nil when path is not in cache", function()
            lsp.invalidate()
            assert.is_nil(lsp.get_items("/workspace/File.al"))
        end)

        it("returns cached entry with correct shape", function()
            local uri   = "file:///workspace/File.al"
            local fpath = vim.fs.normalize(vim.uri_to_fname(uri))

            -- Seed the cache by calling _index_by_file via the al/updateTests handler
            local ctx = { client_id = 200 }
            vim.lsp.handlers["al/updateTests"](nil, {
                testItems = {
                    {
                        name     = "Test App",
                        children = {
                            {
                                name       = "My Codeunit",
                                codeunitId = 50200,
                                children   = {
                                    {
                                        name     = "Test_Foo",
                                        appId    = "abc-123",
                                        codeunitId = 50200,
                                        scope    = 2,
                                        location = {
                                            source = uri,
                                            range  = {
                                                start  = { line = 1, character = 0 },
                                                ["end"] = { line = 1, character = 8 },
                                            },
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            }, ctx, nil)

            local entry = lsp.get_items(fpath)
            assert.is_not_nil(entry)
            assert.are.equal("My Codeunit", entry.codeunit_name)
            assert.are.equal(50200, entry.codeunit_id)
            assert.are.equal(1, #entry.tests)
            assert.are.equal("Test_Foo", entry.tests[1].name)

            lsp.invalidate(200)
        end)
    end)

    -- ── get_client ────────────────────────────────────────────────────────────
    describe("get_client", function()
        it("returns nil when no al_ls clients exist", function()
            local orig = vim.lsp.get_clients
            vim.lsp.get_clients = function() return {} end
            assert.is_nil(lsp.get_client("/workspace/File.al"))
            vim.lsp.get_clients = orig
        end)

        it("returns client whose root_dir is a prefix of the path", function()
            local mock = { id = 1, root_dir = "/workspace", name = "al_ls" }
            local orig = vim.lsp.get_clients
            vim.lsp.get_clients = function() return { mock } end
            assert.are.equal(mock, lsp.get_client("/workspace/Src/File.al"))
            vim.lsp.get_clients = orig
        end)
    end)
```

- [ ] **Step 2: Run tests to verify they fail**

```
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/neotest-al/discovery/lsp_spec.lua" +qa
```

Expected: FAIL — `attempt to call nil value (field 'get_items')` and similar for `get_client`.

- [ ] **Step 3: Add get_items and get_client to discovery/lsp.lua**

After the existing `M._index_by_file = index_by_file` line near the bottom of `lua/neotest-al/discovery/lsp.lua`, add:

```lua
--- Returns the cached test entry for a file path, or nil if not in cache.
--- Used by the LSP runner to get raw LSP test items for al/runTests.
---@param path string  normalized filesystem path
---@return { codeunit_name: string, codeunit_id: integer, tests: table[] }|nil
function M.get_items(path)
    local norm = vim.fs.normalize(path)
    for _, file_cache in pairs(cache) do
        if file_cache[norm] then
            return file_cache[norm]
        end
    end
end

--- Returns the al_ls client responsible for the given path, or nil.
---@param path string
---@return vim.lsp.Client|nil
function M.get_client(path)
    return find_client(path)
end
```

- [ ] **Step 4: Run tests to verify they pass**

```
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/neotest-al/discovery/lsp_spec.lua" +qa
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/neotest-al/discovery/lsp.lua tests/neotest-al/discovery/lsp_spec.lua
git commit -m "feat(discovery/lsp): expose get_items and get_client for runner use"
```

---

## Task 2: runner/lsp/launch.lua

Reads `.vscode/launch.json`, filters AL configs, prompts with `vim.ui.select` when multiple configs exist, and caches the selection per workspace root.

**Files:**
- Create: `lua/neotest-al/runner/lsp/launch.lua`
- Create: `tests/neotest-al/runner/lsp/launch_spec.lua`

- [ ] **Step 1: Write failing tests**

Create `tests/neotest-al/runner/lsp/launch_spec.lua`:

```lua
describe("neotest-al.runner.lsp.launch", function()
    local launch

    before_each(function()
        package.loaded["neotest-al.runner.lsp.launch"] = nil
        launch = require("neotest-al.runner.lsp.launch")
    end)

    -- ── _find_workspace_root ──────────────────────────────────────────────────
    describe("_find_workspace_root", function()
        it("returns nil when no app.json found walking up", function()
            -- /tmp has no app.json above it
            assert.is_nil(launch._find_workspace_root("/tmp/no-project/File.al"))
        end)

        it("finds app.json in parent directory", function()
            -- Use the repo root itself which contains app.json if it exists,
            -- or mock vim.fs.find
            local orig = vim.fs.find
            vim.fs.find = function(name, opts)
                if name == "app.json" then
                    return { "/workspace/app.json" }
                end
                return orig(name, opts)
            end

            local root = launch._find_workspace_root("/workspace/src/File.al")
            vim.fs.find = orig
            assert.are.equal(vim.fs.normalize("/workspace"), root)
        end)
    end)

    -- ── _read_json ────────────────────────────────────────────────────────────
    describe("_read_json", function()
        it("returns nil for a file that does not exist", function()
            assert.is_nil(launch._read_json("/nonexistent/path/launch.json"))
        end)

        it("decodes valid JSON from a file", function()
            local path = vim.fn.tempname() .. ".json"
            local f = io.open(path, "w")
            f:write('{"configurations":[{"type":"al","request":"launch","name":"dev"}]}')
            f:close()

            local data = launch._read_json(path)
            assert.is_not_nil(data)
            assert.are.equal("al", data.configurations[1].type)

            os.remove(path)
        end)
    end)

    -- ── get_config ────────────────────────────────────────────────────────────
    describe("get_config", function()
        local function run_async(fn)
            local nio = require("nio")
            local result, err, done = nil, nil, false
            nio.run(function()
                local ok, val = pcall(fn)
                if ok then result = val else err = val end
                done = true
            end)
            vim.wait(5000, function() return done end, 10)
            if err then error(err, 2) end
            return result
        end

        local function write_launch(path, configs)
            local f = io.open(path, "w")
            f:write(vim.json.encode({ configurations = configs }))
            f:close()
        end

        it("returns nil when launch.json does not exist", function()
            local orig_find = vim.fs.find
            vim.fs.find = function(name, opts)
                if name == "app.json" then return { "/workspace/app.json" } end
                return orig_find(name, opts)
            end

            local result = run_async(function()
                return launch.get_config("/workspace/src/File.al", {
                    launch_json_path = "/nonexistent/launch.json",
                })
            end)

            vim.fs.find = orig_find
            assert.is_nil(result)
        end)

        it("returns nil when no AL configs exist", function()
            local tmp = vim.fn.tempname() .. ".json"
            write_launch(tmp, { { type = "chrome", request = "launch", name = "web" } })

            local orig_find = vim.fs.find
            vim.fs.find = function(name, opts)
                if name == "app.json" then return { "/workspace/app.json" } end
                return orig_find(name, opts)
            end

            local result = run_async(function()
                return launch.get_config("/workspace/src/File.al", { launch_json_path = tmp })
            end)

            vim.fs.find = orig_find
            os.remove(tmp)
            assert.is_nil(result)
        end)

        it("returns the config directly when exactly one AL config exists", function()
            local tmp = vim.fn.tempname() .. ".json"
            write_launch(tmp, {
                { type = "al", request = "launch", name = "dev", server = "https://bc.example.com" },
            })

            local orig_find = vim.fs.find
            vim.fs.find = function(name, opts)
                if name == "app.json" then return { "/workspace/app.json" } end
                return orig_find(name, opts)
            end

            local result = run_async(function()
                return launch.get_config("/workspace/src/File.al", { launch_json_path = tmp })
            end)

            vim.fs.find = orig_find
            os.remove(tmp)
            assert.is_not_nil(result)
            assert.are.equal("dev", result.name)
            assert.are.equal("https://bc.example.com", result.server)
        end)

        it("calls vim.ui.select and returns chosen config when multiple AL configs exist", function()
            local tmp = vim.fn.tempname() .. ".json"
            write_launch(tmp, {
                { type = "al", request = "launch", name = "dev",  server = "https://dev.example.com" },
                { type = "al", request = "launch", name = "test", server = "https://test.example.com" },
            })

            local orig_find  = vim.fs.find
            local orig_select = vim.ui.select
            vim.fs.find = function(name, opts)
                if name == "app.json" then return { "/workspace/app.json" } end
                return orig_find(name, opts)
            end
            -- Simulate the user picking the second option
            vim.ui.select = function(items, opts, cb) cb(items[2], 2) end

            local result = run_async(function()
                return launch.get_config("/workspace/src/File.al", { launch_json_path = tmp })
            end)

            vim.fs.find  = orig_find
            vim.ui.select = orig_select
            os.remove(tmp)
            assert.is_not_nil(result)
            assert.are.equal("test", result.name)
        end)

        it("returns nil when user cancels vim.ui.select", function()
            local tmp = vim.fn.tempname() .. ".json"
            write_launch(tmp, {
                { type = "al", request = "launch", name = "dev" },
                { type = "al", request = "launch", name = "test" },
            })

            local orig_find  = vim.fs.find
            local orig_select = vim.ui.select
            vim.fs.find = function(name, opts)
                if name == "app.json" then return { "/workspace/app.json" } end
                return orig_find(name, opts)
            end
            vim.ui.select = function(items, opts, cb) cb(nil, nil) end

            local result = run_async(function()
                return launch.get_config("/workspace/src/File.al", { launch_json_path = tmp })
            end)

            vim.fs.find  = orig_find
            vim.ui.select = orig_select
            os.remove(tmp)
            assert.is_nil(result)
        end)
    end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

```
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/neotest-al/runner/lsp/launch_spec.lua" +qa
```

Expected: FAIL — module not found.

- [ ] **Step 3: Create lua/neotest-al/runner/lsp/launch.lua**

```lua
local nio = require("nio")

local M = {}

-- Walk up from path looking for app.json to find workspace root.
---@param path string
---@return string|nil  normalized workspace root path
local function find_workspace_root(path)
    local found = vim.fs.find("app.json", {
        path   = vim.fs.dirname(vim.fs.normalize(path)),
        upward = true,
        limit  = 1,
    })
    if found and #found > 0 then
        return vim.fs.normalize(vim.fs.dirname(found[1]))
    end
end

-- Read and JSON-decode a file. Returns nil on any error.
---@param path string
---@return table|nil
local function read_json(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    local ok, data = pcall(vim.json.decode, content)
    if ok and type(data) == "table" then return data end
end

-- Per-workspace selected config cache.
-- Invalidated when launch.json changes on disk.
local config_cache = {}
local watching     = {}

local function watch_launch_json(launch_path, root)
    local norm = vim.fs.normalize(launch_path)
    if watching[norm] then return end
    watching[norm] = true
    vim.api.nvim_create_autocmd("BufWritePost", {
        pattern  = norm,
        callback = function() config_cache[root] = nil end,
    })
end

-- Get the AL launch configuration for the workspace containing file_path.
-- Reads .vscode/launch.json (or opts.launch_json_path), filters type=="al",
-- prompts with vim.ui.select when multiple configs exist, caches the result.
--
-- @async — must be called inside a nio coroutine.
---@param file_path string
---@param opts? { launch_json_path?: string }
---@return table|nil  selected launch configuration, or nil on error/cancel
function M.get_config(file_path, opts)
    opts = opts or {}

    local root = find_workspace_root(file_path)
    if not root then
        vim.notify(
            "neotest-al: could not find workspace root (app.json) for " .. file_path,
            vim.log.levels.ERROR
        )
        return nil
    end

    -- Return cached selection
    if config_cache[root] then
        return config_cache[root]
    end

    -- Resolve launch.json path
    local launch_path
    if opts.launch_json_path then
        if vim.fn.isabsolutepath(opts.launch_json_path) == 1 then
            launch_path = opts.launch_json_path
        else
            launch_path = root .. "/" .. opts.launch_json_path
        end
    else
        launch_path = root .. "/.vscode/launch.json"
    end
    launch_path = vim.fs.normalize(launch_path)

    watch_launch_json(launch_path, root)

    local data = read_json(launch_path)
    if not data or not data.configurations then
        vim.notify(
            "neotest-al: launch.json not found or invalid at " .. launch_path,
            vim.log.levels.ERROR
        )
        return nil
    end

    -- Filter AL launch configs
    local al_configs = {}
    for _, cfg in ipairs(data.configurations) do
        if cfg.type == "al" and cfg.request == "launch" then
            table.insert(al_configs, cfg)
        end
    end

    if #al_configs == 0 then
        vim.notify(
            "neotest-al: no AL launch configurations found in " .. launch_path,
            vim.log.levels.ERROR
        )
        return nil
    end

    if #al_configs == 1 then
        config_cache[root] = al_configs[1]
        return al_configs[1]
    end

    -- Multiple configs: prompt user via vim.ui.select (async)
    local select = nio.wrap(vim.ui.select, 3)
    local choice, idx = select(al_configs, {
        prompt      = "Select AL launch configuration:",
        format_item = function(cfg) return cfg.name or "(unnamed)" end,
    })

    if not idx then return nil end

    config_cache[root] = al_configs[idx]
    return al_configs[idx]
end

-- Test-only exports
M._find_workspace_root = find_workspace_root
M._read_json           = read_json
M._config_cache        = config_cache

return M
```

- [ ] **Step 4: Run tests to verify they pass**

```
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/neotest-al/runner/lsp/launch_spec.lua" +qa
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/neotest-al/runner/lsp/launch.lua tests/neotest-al/runner/lsp/launch_spec.lua
git commit -m "feat(runner/lsp): add launch.lua — launch.json reader with config selection"
```

---

## Task 3: runner/lsp/dirty.lua

Tracks whether any `.al` file in a workspace has been saved since the last successful publish, to control `SkipPublish` in `al/runTests`.

**Files:**
- Create: `lua/neotest-al/runner/lsp/dirty.lua`
- Create: `tests/neotest-al/runner/lsp/dirty_spec.lua`

- [ ] **Step 1: Write failing tests**

Create `tests/neotest-al/runner/lsp/dirty_spec.lua`:

```lua
describe("neotest-al.runner.lsp.dirty", function()
    local dirty

    before_each(function()
        package.loaded["neotest-al.runner.lsp.dirty"] = nil
        dirty = require("neotest-al.runner.lsp.dirty")
    end)

    it("is_dirty returns true for a workspace that has never been published", function()
        assert.is_true(dirty.is_dirty("/workspace/project"))
    end)

    it("is_dirty returns false after mark_clean", function()
        dirty.mark_clean("/workspace/project")
        assert.is_false(dirty.is_dirty("/workspace/project"))
    end)

    it("is_dirty returns true again after mark_dirty", function()
        dirty.mark_clean("/workspace/project")
        dirty.mark_dirty("/workspace/project")
        assert.is_true(dirty.is_dirty("/workspace/project"))
    end)

    it("mark_dirty on an untracked workspace does not error", function()
        assert.has_no.errors(function()
            dirty.mark_dirty("/workspace/unknown")
        end)
        assert.is_true(dirty.is_dirty("/workspace/unknown"))
    end)

    it("mark_clean on an untracked workspace does not error", function()
        assert.has_no.errors(function()
            dirty.mark_clean("/workspace/unknown2")
        end)
        assert.is_false(dirty.is_dirty("/workspace/unknown2"))
    end)

    it("tracking is independent per workspace root", function()
        dirty.mark_clean("/workspace/a")
        dirty.mark_clean("/workspace/b")
        dirty.mark_dirty("/workspace/a")
        assert.is_true(dirty.is_dirty("/workspace/a"))
        assert.is_false(dirty.is_dirty("/workspace/b"))
    end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

```
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/neotest-al/runner/lsp/dirty_spec.lua" +qa
```

Expected: FAIL — module not found.

- [ ] **Step 3: Create lua/neotest-al/runner/lsp/dirty.lua**

```lua
local M = {}

-- dirty[root] = true  → files have been saved since last publish
-- published[root] = true  → at least one successful publish has occurred
local dirty     = {}
local published = {}

--- Returns true if the workspace has unsaved changes since last publish,
--- or if no publish has ever succeeded (first run must always publish).
---@param root string  normalized workspace root path
---@return boolean
function M.is_dirty(root)
    return dirty[root] == true or published[root] ~= true
end

--- Mark workspace as having changes since last publish.
---@param root string
function M.mark_dirty(root)
    dirty[root] = true
end

--- Mark workspace as clean (successful publish just completed).
---@param root string
function M.mark_clean(root)
    dirty[root]     = nil
    published[root] = true
end

-- Register a global BufWritePost autocmd for *.al files.
-- On each save, walk up to app.json to find the workspace root and mark dirty.
vim.api.nvim_create_autocmd("BufWritePost", {
    group   = vim.api.nvim_create_augroup("neotest_al_dirty_tracker", { clear = true }),
    pattern = "*.al",
    callback = function(args)
        local file_path = args.match or args.file
        if not file_path then return end
        local found = vim.fs.find("app.json", {
            path   = vim.fs.dirname(vim.fs.normalize(file_path)),
            upward = true,
            limit  = 1,
        })
        if found and #found > 0 then
            local root = vim.fs.normalize(vim.fs.dirname(found[1]))
            M.mark_dirty(root)
        end
    end,
})

return M
```

- [ ] **Step 4: Run tests to verify they pass**

```
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/neotest-al/runner/lsp/dirty_spec.lua" +qa
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/neotest-al/runner/lsp/dirty.lua tests/neotest-al/runner/lsp/dirty_spec.lua
git commit -m "feat(runner/lsp): add dirty.lua — BufWritePost-based SkipPublish tracking"
```

---

## Task 4: runner/lsp/diagnostics.lua

Parses AL compiler error lines from `al/testExecutionMessage` and sets them as Neovim diagnostics.

**Files:**
- Create: `lua/neotest-al/runner/lsp/diagnostics.lua`
- Create: `tests/neotest-al/runner/lsp/diagnostics_spec.lua`

- [ ] **Step 1: Write failing tests**

Create `tests/neotest-al/runner/lsp/diagnostics_spec.lua`:

```lua
describe("neotest-al.runner.lsp.diagnostics", function()
    local diag

    before_each(function()
        package.loaded["neotest-al.runner.lsp.diagnostics"] = nil
        diag = require("neotest-al.runner.lsp.diagnostics")
    end)

    -- ── parse_line ────────────────────────────────────────────────────────────
    describe("parse_line", function()
        it("returns nil for a plain log line", function()
            assert.is_nil(diag.parse_line("[2026-04-02] Preparing to build and publish projects..."))
        end)

        it("returns nil for an empty string", function()
            assert.is_nil(diag.parse_line(""))
        end)

        it("parses an error line correctly", function()
            local item = diag.parse_line(
                "c:/repos/myapp/src/Foo.al(12,4): error AL0001: Symbol 'Foo' is not found"
            )
            assert.is_not_nil(item)
            assert.are.equal(vim.fs.normalize("c:/repos/myapp/src/Foo.al"), item.file)
            assert.are.equal(12, item.line)
            assert.are.equal(4, item.col)
            assert.are.equal("error", item.severity)
            assert.are.equal("AL0001", item.code)
            assert.are.equal("Symbol 'Foo' is not found", item.message)
        end)

        it("parses a warning line correctly", function()
            local item = diag.parse_line(
                "c:/repos/myapp/src/Bar.al(5,10): warning AL0002: Unused variable 'x'"
            )
            assert.is_not_nil(item)
            assert.are.equal("warning", item.severity)
            assert.are.equal(5, item.line)
            assert.are.equal(10, item.col)
        end)

        it("returns nil for info severity lines", function()
            assert.is_nil(diag.parse_line(
                "c:/repos/myapp/src/Bar.al(1,1): info AL9999: Some informational note"
            ))
        end)

        it("handles Windows-style backslash paths", function()
            local item = diag.parse_line(
                "c:\\repos\\myapp\\src\\Foo.al(3,1): error AL0001: Test"
            )
            -- Should still parse (path normalised by caller)
            assert.is_not_nil(item)
            assert.are.equal(3, item.line)
        end)
    end)

    -- ── set and clear ─────────────────────────────────────────────────────────
    describe("set and clear", function()
        it("set does not error when given an empty list", function()
            assert.has_no.errors(function() diag.set({}) end)
        end)

        it("clear does not error", function()
            assert.has_no.errors(function() diag.clear() end)
        end)

        it("set does not error with valid error items", function()
            -- We can't easily test the actual diagnostic output in a headless
            -- environment without a real buffer, so just verify no crash.
            assert.has_no.errors(function()
                diag.set({
                    {
                        file     = vim.fn.tempname() .. ".al",
                        line     = 5,
                        col      = 1,
                        severity = "error",
                        code     = "AL0001",
                        message  = "Test error",
                    },
                })
            end)
        end)
    end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

```
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/neotest-al/runner/lsp/diagnostics_spec.lua" +qa
```

Expected: FAIL — module not found.

- [ ] **Step 3: Create lua/neotest-al/runner/lsp/diagnostics.lua**

```lua
local M = {}

local NS = vim.api.nvim_create_namespace("neotest-al-build")

-- AL compiler error format:
--   /path/to/File.al(line,col): error|warning AL0000: message
-- Backslash paths (Windows) also work because Lua patterns treat \ literally.
-- Pattern captures: file, line, col, severity, code, message
local PATTERN = "^(.-)%((%d+),(%d+)%):%s*(error|warning)%s+(%S+):%s+(.+)$"

--- Parse a single al/testExecutionMessage line.
--- Returns a structured error item, or nil if the line is not a compiler diagnostic.
---@param line string
---@return { file: string, line: integer, col: integer, severity: string, code: string, message: string }|nil
function M.parse_line(line)
    local file, ln, col, severity, code, msg = line:match(PATTERN)
    if not file then return nil end
    return {
        file     = vim.fs.normalize(file),
        line     = tonumber(ln),
        col      = tonumber(col),
        severity = severity,
        code     = code,
        message  = msg,
    }
end

--- Set vim diagnostics for a list of parsed build errors.
--- Errors and warnings are shown; info lines are excluded by parse_line already.
---@param errors { file: string, line: integer, col: integer, severity: string, code: string, message: string }[]
function M.set(errors)
    if #errors == 0 then return end

    -- Group by file
    local by_file = {}
    for _, e in ipairs(errors) do
        if not by_file[e.file] then by_file[e.file] = {} end
        local sev = e.severity == "error"
            and vim.diagnostic.severity.ERROR
            or  vim.diagnostic.severity.WARN
        table.insert(by_file[e.file], {
            lnum     = e.line - 1,  -- 0-based
            col      = e.col - 1,   -- 0-based
            severity = sev,
            message  = ("[%s] %s"):format(e.code, e.message),
            source   = "neotest-al",
        })
    end

    for file, diags in pairs(by_file) do
        local bufnr = vim.fn.bufadd(file)
        vim.diagnostic.set(NS, bufnr, diags)
    end
end

--- Clear all build diagnostics set by this module.
function M.clear()
    vim.diagnostic.reset(NS)
end

return M
```

- [ ] **Step 4: Run tests to verify they pass**

```
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/neotest-al/runner/lsp/diagnostics_spec.lua" +qa
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/neotest-al/runner/lsp/diagnostics.lua tests/neotest-al/runner/lsp/diagnostics_spec.lua
git commit -m "feat(runner/lsp): add diagnostics.lua — AL compiler error parsing and vim.diagnostic"
```

---

## Task 5: runner/lsp/run.lua

Sends `al/runTests`, wires global LSP notification handlers per active run, accumulates results, and writes a JSON temp file when `al/testRunComplete` fires.

**Files:**
- Create: `lua/neotest-al/runner/lsp/run.lua`
- Create: `tests/neotest-al/runner/lsp/run_spec.lua`

- [ ] **Step 1: Write failing tests**

Create `tests/neotest-al/runner/lsp/run_spec.lua`:

```lua
describe("neotest-al.runner.lsp.run", function()
    local run

    before_each(function()
        package.loaded["neotest-al.runner.lsp.run"] = nil
        -- diagnostics is a dep; stub it to avoid side effects
        package.loaded["neotest-al.runner.lsp.diagnostics"] = {
            parse_line = function(line)
                -- simple stub: detect "error" keyword
                if line:match("%((%d+),(%d+)%):%s*error") then
                    local file, ln, col = line:match("^(.-)%((%d+),(%d+)%)")
                    return { file = file, line = tonumber(ln), col = tonumber(col),
                             severity = "error", code = "AL0000", message = "stub" }
                end
            end,
            set   = function() end,
            clear = function() end,
        }
        run = require("neotest-al.runner.lsp.run")
    end)

    after_each(function()
        -- Clean up any leftover active run state
        run._reset()
    end)

    -- Helper: run async function
    local function run_async(fn)
        local nio    = require("nio")
        local result, err, done = nil, nil, false
        nio.run(function()
            local ok, val = pcall(fn)
            if ok then result = val else err = val end
            done = true
        end)
        vim.wait(5000, function() return done end, 10)
        if err then error(err, 2) end
        return result
    end

    -- Helper: simulate a client
    local function make_client(id)
        return {
            id = id,
            request = function(self, method, params, cb)
                -- Immediately acknowledge (no result, no error)
                vim.schedule(function() cb(nil, nil) end)
                return true, id
            end,
        }
    end

    -- Helper: fire a notification as if the LSP server sent it
    local function fire(method, result, client_id)
        local handler = vim.lsp.handlers[method]
        if handler then
            handler(nil, result, { client_id = client_id }, nil)
        end
    end

    it("accumulates test results from al/testMethodFinish", function()
        local client = make_client(300)
        local results_path = vim.fn.tempname() .. ".json"

        run_async(function()
            -- Start execute in a concurrent coroutine so we can fire events
            local nio = require("nio")
            local done = false
            nio.run(function()
                run.execute(client, {}, {}, results_path, false)
                done = true
            end)

            -- Let the request fire
            nio.sleep(50)

            -- Simulate test lifecycle
            fire("al/testMethodStart",  { name = "",       codeunitId = 400 }, 300)
            fire("al/testMethodStart",  { name = "TestA",  codeunitId = 400 }, 300)
            fire("al/testMethodFinish", { name = "TestA",  codeunitId = 400, status = 0, message = "", duration = 50 }, 300)
            fire("al/testMethodFinish", { name = "",       codeunitId = 400, status = 0, message = "", duration = 50 }, 300)
            fire("al/testRunComplete",  {}, 300)

            vim.wait(2000, function() return done end, 10)
        end)

        -- Read the results file
        local f = io.open(results_path, "r")
        assert.is_not_nil(f)
        local data = vim.json.decode(f:read("*a"))
        f:close()
        os.remove(results_path)

        assert.are.equal(1, #data.tests)
        assert.are.equal("TestA", data.tests[1].name)
        assert.are.equal(400, data.tests[1].codeunit_id)
        assert.are.equal(0, data.tests[1].status)
        assert.are.equal(50, data.tests[1].duration)
    end)

    it("skips empty-name testMethodFinish (codeunit-level finish)", function()
        local client = make_client(301)
        local results_path = vim.fn.tempname() .. ".json"

        run_async(function()
            local nio = require("nio")
            local done = false
            nio.run(function()
                run.execute(client, {}, {}, results_path, false)
                done = true
            end)
            nio.sleep(50)
            fire("al/testMethodFinish", { name = "", codeunitId = 401, status = 0, message = "", duration = 10 }, 301)
            fire("al/testRunComplete",  {}, 301)
            vim.wait(2000, function() return done end, 10)
        end)

        local f = io.open(results_path, "r")
        local data = vim.json.decode(f:read("*a"))
        f:close()
        os.remove(results_path)

        assert.are.equal(0, #data.tests)
    end)

    it("sets auth_error flag when build message contains Unauthorized", function()
        local client = make_client(302)
        local results_path = vim.fn.tempname() .. ".json"
        local notified = false
        local orig_notify = vim.notify
        vim.notify = function(msg, level)
            if msg:match("authentication failed") then notified = true end
        end

        run_async(function()
            local nio = require("nio")
            local done = false
            nio.run(function()
                run.execute(client, {}, {}, results_path, false)
                done = true
            end)
            nio.sleep(50)
            fire("al/testExecutionMessage", "Unauthorized access to server\r\n", 302)
            fire("al/testRunComplete", {}, 302)
            vim.wait(2000, function() return done end, 10)
        end)

        vim.notify = orig_notify
        os.remove(results_path)
        assert.is_true(notified)
    end)

    it("accumulates build log lines", function()
        local client = make_client(303)
        local results_path = vim.fn.tempname() .. ".json"

        run_async(function()
            local nio = require("nio")
            local done = false
            nio.run(function()
                run.execute(client, {}, {}, results_path, false)
                done = true
            end)
            nio.sleep(50)
            fire("al/testExecutionMessage", "[2026-04-02] Starting build\r\n", 303)
            fire("al/testExecutionMessage", "[2026-04-02] Build complete\r\n", 303)
            fire("al/testRunComplete", {}, 303)
            vim.wait(2000, function() return done end, 10)
        end)

        local f = io.open(results_path, "r")
        local data = vim.json.decode(f:read("*a"))
        f:close()
        os.remove(results_path)

        assert.are.equal(2, #data.build_log)
    end)

    it("returns true when no build errors occurred", function()
        local client = make_client(304)
        local results_path = vim.fn.tempname() .. ".json"
        local success

        run_async(function()
            local nio = require("nio")
            local done = false
            nio.run(function()
                success = run.execute(client, {}, {}, results_path, false)
                done = true
            end)
            nio.sleep(50)
            fire("al/testRunComplete", {}, 304)
            vim.wait(2000, function() return done end, 10)
        end)

        os.remove(results_path)
        assert.is_true(success)
    end)

    it("returns false when build errors are present", function()
        local client = make_client(305)
        local results_path = vim.fn.tempname() .. ".json"
        local success

        run_async(function()
            local nio = require("nio")
            local done = false
            nio.run(function()
                success = run.execute(client, {}, {}, results_path, false)
                done = true
            end)
            nio.sleep(50)
            fire("al/testExecutionMessage", "c:/src/Foo.al(1,1): error AL0001: Test", 305)
            fire("al/testRunComplete", {}, 305)
            vim.wait(2000, function() return done end, 10)
        end)

        os.remove(results_path)
        assert.is_false(success)
    end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

```
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/neotest-al/runner/lsp/run_spec.lua" +qa
```

Expected: FAIL — module not found.

- [ ] **Step 3: Create lua/neotest-al/runner/lsp/run.lua**

```lua
local nio         = require("nio")
local diagnostics = require("neotest-al.runner.lsp.diagnostics")

local M = {}

-- Active run state, keyed by client_id.
-- Each run holds the accumulated data until al/testRunComplete fires.
-- { done, build_log, build_errors, tests, auth_error }
local active_runs = {}

-- Auth error patterns (case-insensitive match)
local AUTH_PATTERNS = { "unauthorized", "401", "authentication failed" }

local function is_auth_error(line)
    local lower = line:lower()
    for _, pat in ipairs(AUTH_PATTERNS) do
        if lower:find(pat, 1, true) then return true end
    end
    return false
end

-- Wire global LSP notification handlers once at module load.
-- Each handler filters by client_id so only active runs are touched.
local function setup_handlers()
    local prev_msg    = vim.lsp.handlers["al/testExecutionMessage"]
    local prev_start  = vim.lsp.handlers["al/testMethodStart"]
    local prev_finish = vim.lsp.handlers["al/testMethodFinish"]
    local prev_done   = vim.lsp.handlers["al/testRunComplete"]

    vim.lsp.handlers["al/testExecutionMessage"] = function(err, result, ctx, config)
        local state = active_runs[ctx.client_id]
        if state and type(result) == "string" then
            table.insert(state.build_log, result)
            if is_auth_error(result) then
                state.auth_error = true
            end
            local err_item = diagnostics.parse_line(result)
            if err_item then
                table.insert(state.build_errors, err_item)
            end
        end
        if prev_msg then prev_msg(err, result, ctx, config) end
    end

    vim.lsp.handlers["al/testMethodStart"] = function(err, result, ctx, config)
        if prev_start then prev_start(err, result, ctx, config) end
    end

    vim.lsp.handlers["al/testMethodFinish"] = function(err, result, ctx, config)
        local state = active_runs[ctx.client_id]
        if state and result and type(result.name) == "string" and result.name ~= "" then
            table.insert(state.tests, {
                name        = result.name,
                codeunit_id = result.codeunitId,
                status      = result.status,
                message     = result.message or "",
                duration    = result.duration or 0,
            })
        end
        if prev_finish then prev_finish(err, result, ctx, config) end
    end

    vim.lsp.handlers["al/testRunComplete"] = function(err, result, ctx, config)
        local state = active_runs[ctx.client_id]
        if state then
            state.done = true
        end
        if prev_done then prev_done(err, result, ctx, config) end
    end
end

setup_handlers()

-- Maximum ticks to wait for al/testRunComplete before timing out (5 minutes).
local MAX_TICKS = 15000  -- 15000 × 20 ms = 300 s

--- Send al/runTests and block until al/testRunComplete fires (or timeout).
--- Writes accumulated results to results_path as JSON.
---
--- @async — must be called inside a nio coroutine.
---@param client       vim.lsp.Client
---@param config       table     launch.json configuration object
---@param test_items   table[]   raw LSP test item objects for al/runTests
---@param results_path string    path to write JSON results file
---@param skip_publish boolean   passed as SkipPublish to al/runTests
---@return boolean  true when run completed with no build errors
function M.execute(client, config, test_items, results_path, skip_publish)
    diagnostics.clear()

    local state = {
        done         = false,
        build_log    = {},
        build_errors = {},
        tests        = {},
        auth_error   = false,
    }
    active_runs[client.id] = state

    -- Fire al/runTests (response has no value; we wait for al/testRunComplete)
    client:request("al/runTests", {
        configuration          = config,
        Tests                  = test_items,
        SkipPublish            = skip_publish,
        VSCodeExtensionVersion = "18.0.0",
        CoverageMode           = "none",
        Args                   = {},
    }, function() end)

    -- Wait for al/testRunComplete
    local ticks = 0
    while not state.done and ticks < MAX_TICKS do
        nio.sleep(20)
        ticks = ticks + 1
    end

    active_runs[client.id] = nil

    if state.auth_error then
        vim.notify(
            "neotest-al: AL authentication failed — run :AL authenticate",
            vim.log.levels.ERROR
        )
    end

    -- Write results file
    local ok, encoded = pcall(vim.json.encode, {
        build_log    = state.build_log,
        build_errors = state.build_errors,
        tests        = state.tests,
    })
    if ok then
        local f = io.open(results_path, "w")
        if f then
            f:write(encoded)
            f:close()
        end
    end

    return #state.build_errors == 0
end

-- Test-only: reset active_runs to isolate tests.
function M._reset()
    active_runs = {}
end

return M
```

- [ ] **Step 4: Run tests to verify they pass**

```
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/neotest-al/runner/lsp/run_spec.lua" +qa
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/neotest-al/runner/lsp/run.lua tests/neotest-al/runner/lsp/run_spec.lua
git commit -m "feat(runner/lsp): add run.lua — al/runTests execution and result streaming"
```

---

## Task 6: runner/lsp/init.lua

Orchestrates all sub-modules. `build_spec` collects test items, selects the launch config, calls `run.execute`, and returns a spec. `results` reads the JSON file and maps test outcomes to neotest's result format.

**Files:**
- Create: `lua/neotest-al/runner/lsp/init.lua`
- Create: `tests/neotest-al/runner/lsp/init_spec.lua`

- [ ] **Step 1: Write failing tests**

Create `tests/neotest-al/runner/lsp/init_spec.lua`:

```lua
describe("neotest-al.runner.lsp.init", function()
    local lsp_runner

    -- Stub sub-modules so tests are isolated
    local stub_launch, stub_dirty, stub_run

    before_each(function()
        package.loaded["neotest-al.runner.lsp.init"]        = nil
        package.loaded["neotest-al.runner.lsp.launch"]      = nil
        package.loaded["neotest-al.runner.lsp.dirty"]       = nil
        package.loaded["neotest-al.runner.lsp.run"]         = nil
        package.loaded["neotest-al.runner.lsp.diagnostics"] = nil

        stub_launch = {
            get_config   = function() return { type = "al", name = "dev" } end,
            _find_workspace_root = function() return "/workspace" end,
            _read_json   = function() end,
            _config_cache = {},
        }
        stub_dirty = {
            is_dirty   = function() return true end,
            mark_clean = function() end,
            mark_dirty = function() end,
        }
        stub_run = {
            execute = function(client, config, items, path, skip)
                -- Write a minimal results file
                local f = io.open(path, "w")
                f:write(vim.json.encode({ build_log = {}, build_errors = {}, tests = {
                    { name = "TestA", codeunit_id = 500, status = 0, message = "", duration = 10 },
                } }))
                f:close()
                return true
            end,
            _reset = function() end,
        }

        package.loaded["neotest-al.runner.lsp.launch"]      = stub_launch
        package.loaded["neotest-al.runner.lsp.dirty"]       = stub_dirty
        package.loaded["neotest-al.runner.lsp.run"]         = stub_run
        package.loaded["neotest-al.runner.lsp.diagnostics"] = { set = function() end, clear = function() end, parse_line = function() end }

        lsp_runner = require("neotest-al.runner.lsp.init").new()
    end)

    local function run_async(fn)
        local nio = require("nio")
        local result, err, done = nil, nil, false
        nio.run(function()
            local ok, val = pcall(fn)
            if ok then result = val else err = val end
            done = true
        end)
        vim.wait(5000, function() return done end, 10)
        if err then error(err, 2) end
        return result
    end

    local function make_tree(type, path, name, id, codeunit_id, children)
        children = children or {}
        return {
            data     = function() return { type = type, path = path, name = name, id = id } end,
            children = function() return children end,
        }
    end

    local function make_discovery(items_by_path, client)
        return {
            get_items  = function(path) return items_by_path[vim.fs.normalize(path)] end,
            get_client = function(path) return client end,
            discover_positions = function() end,
            invalidate = function() end,
        }
    end

    -- ── build_spec ─────────────────────────────────────────────────────────────
    describe("build_spec", function()
        it("returns nil when discovery does not expose get_items", function()
            local discovery = { discover_positions = function() end, invalidate = function() end }
            local runner = require("neotest-al.runner.lsp.init").new()
            local spec = run_async(function()
                return runner.build_spec({ tree = make_tree("test", "/ws/F.al", "TestA", "/ws/F.al::TestA") }, discovery)
            end)
            assert.is_nil(spec)
        end)

        it("returns nil when no client found", function()
            local discovery = make_discovery({}, nil)
            local spec = run_async(function()
                return lsp_runner.build_spec(
                    { tree = make_tree("test", "/ws/F.al", "TestA", "/ws/F.al::TestA") },
                    discovery
                )
            end)
            assert.is_nil(spec)
        end)

        it("returns nil when no test items collected", function()
            local client    = { id = 600, root_dir = "/ws" }
            local discovery = make_discovery({}, client)  -- empty — get_items returns nil
            local spec = run_async(function()
                return lsp_runner.build_spec(
                    { tree = make_tree("test", "/ws/F.al", "TestA", "/ws/F.al::TestA") },
                    discovery
                )
            end)
            assert.is_nil(spec)
        end)

        it("returns spec with results_path and id_map", function()
            local client = { id = 601, root_dir = "/ws" }
            local norm   = vim.fs.normalize("/ws/F.al")
            local discovery = make_discovery({
                [norm] = {
                    codeunit_name = "My Codeunit",
                    codeunit_id   = 500,
                    tests = {
                        { name = "TestA", appId = "abc", codeunitId = 500, scope = 2,
                          location = { source = "file:///ws/F.al", range = { start = { line = 1, character = 0 }, ["end"] = { line = 1, character = 5 } } } },
                    },
                },
            }, client)

            local tree = make_tree("test", "/ws/F.al", "TestA", norm .. "::TestA")
            local spec = run_async(function()
                return lsp_runner.build_spec({ tree = tree }, discovery)
            end)

            assert.is_not_nil(spec)
            assert.is_not_nil(spec.context.results_path)
            assert.is_not_nil(spec.context.id_map)
            assert.are.equal(norm .. "::TestA", spec.context.id_map["500:TestA"])
        end)
    end)

    -- ── results ────────────────────────────────────────────────────────────────
    describe("results", function()
        local function write_results(path, data)
            local f = io.open(path, "w")
            f:write(vim.json.encode(data))
            f:close()
        end

        it("maps passed test to neotest passed status", function()
            local path = vim.fn.tempname() .. ".json"
            write_results(path, {
                build_log    = {},
                build_errors = {},
                tests        = { { name = "TestA", codeunit_id = 500, status = 0, message = "", duration = 42 } },
            })

            local spec = { context = { results_path = path, id_map = { ["500:TestA"] = "/ws/F.al::TestA" } } }
            local out  = lsp_runner.results(spec, {}, make_tree("file", "/ws/F.al", "My Codeunit", "/ws/F.al"))

            os.remove(path)
            assert.are.equal("passed", out["/ws/F.al::TestA"].status)
            assert.are.equal(42,       out["/ws/F.al::TestA"].duration)
        end)

        it("maps failed test to neotest failed status with message", function()
            local path = vim.fn.tempname() .. ".json"
            write_results(path, {
                build_log    = {},
                build_errors = {},
                tests        = { { name = "TestA", codeunit_id = 500, status = 1, message = "Assert failed", duration = 5 } },
            })

            local spec = { context = { results_path = path, id_map = { ["500:TestA"] = "/ws/F.al::TestA" } } }
            local out  = lsp_runner.results(spec, {}, make_tree("file", "/ws/F.al", "My Codeunit", "/ws/F.al"))

            os.remove(path)
            assert.are.equal("failed",       out["/ws/F.al::TestA"].status)
            assert.are.equal("Assert failed", out["/ws/F.al::TestA"].short)
        end)

        it("maps skipped test to neotest skipped status", function()
            local path = vim.fn.tempname() .. ".json"
            write_results(path, {
                build_log    = {},
                build_errors = {},
                tests        = { { name = "TestA", codeunit_id = 500, status = 2, message = "", duration = 0 } },
            })

            local spec = { context = { results_path = path, id_map = { ["500:TestA"] = "/ws/F.al::TestA" } } }
            local out  = lsp_runner.results(spec, {}, make_tree("file", "/ws/F.al", "My Codeunit", "/ws/F.al"))

            os.remove(path)
            assert.are.equal("skipped", out["/ws/F.al::TestA"].status)
        end)

        it("marks all tree nodes failed on build error with no tests", function()
            local path = vim.fn.tempname() .. ".json"
            write_results(path, {
                build_log    = { "output" },
                build_errors = { { file = "/ws/F.al", line = 1, col = 1, severity = "error", code = "AL0001", message = "oops" } },
                tests        = {},
            })

            local test_node = make_tree("test", "/ws/F.al", "TestA", "/ws/F.al::TestA")
            local file_node = make_tree("file", "/ws/F.al", "My Codeunit", "/ws/F.al", nil, { test_node })
            local spec = { context = { results_path = path, id_map = {} } }
            local out  = lsp_runner.results(spec, {}, file_node)

            os.remove(path)
            assert.are.equal("failed", out["/ws/F.al"].status)
            assert.are.equal("failed", out["/ws/F.al::TestA"].status)
            assert.is_not_nil(out["/ws/F.al"].short:match("Build failed"))
        end)

        it("returns empty table when results file is missing", function()
            local spec = { context = { results_path = "/nonexistent.json", id_map = {} } }
            local out  = lsp_runner.results(spec, {}, make_tree("file", "/ws/F.al", "x", "/ws/F.al"))
            assert.are.same({}, out)
        end)
    end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

```
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/neotest-al/runner/lsp/init_spec.lua" +qa
```

Expected: FAIL — module not found.

- [ ] **Step 3: Create lua/neotest-al/runner/lsp/init.lua**

```lua
local nio         = require("nio")
local launch      = require("neotest-al.runner.lsp.launch")
local dirty       = require("neotest-al.runner.lsp.dirty")
local run         = require("neotest-al.runner.lsp.run")
local diagnostics = require("neotest-al.runner.lsp.diagnostics")

local M = {}
M.name = "lsp"

-- Recursively walk a neotest Tree and collect raw LSP test items + position id_map.
-- Returns items[], id_map where id_map["codeunit_id:test_name"] = position_id.
---@param tree neotest.Tree
---@param discovery neotest-al.Discovery
---@return table[], table<string, string>
local function collect_items(tree, discovery)
    local items  = {}
    local id_map = {}

    local function traverse(node)
        local data = node:data()
        if data.type == "test" then
            local file_data = discovery.get_items(data.path)
            if file_data then
                for _, raw in ipairs(file_data.tests or {}) do
                    if raw.name == data.name then
                        table.insert(items, raw)
                        local key = tostring(file_data.codeunit_id) .. ":" .. data.name
                        id_map[key] = data.id
                        break
                    end
                end
            end
        end
        for _, child in ipairs(node:children() or {}) do
            traverse(child)
        end
    end

    traverse(tree)
    return items, id_map
end

--- Create a new LSP runner instance.
---@param opts? { launch_json_path?: string, vscode_extension_version?: string }
---@return neotest-al.Runner
function M.new(opts)
    opts = opts or {}
    local runner = { name = "lsp" }

    ---@async
    function runner.build_spec(args, discovery)
        -- Require the LSP discovery's get_items / get_client extensions
        if type(discovery.get_items) ~= "function" or type(discovery.get_client) ~= "function" then
            vim.notify(
                "neotest-al: LSP runner requires LSP discovery (discovery.get_items not found)",
                vim.log.levels.ERROR
            )
            return nil
        end

        local position = args.tree:data()

        -- Find the client for this workspace
        local client = discovery.get_client(position.path)
        if not client then
            vim.notify(
                "neotest-al: no AL LSP client found for " .. tostring(position.path),
                vim.log.levels.ERROR
            )
            return nil
        end

        -- Collect raw LSP test items + build the id_map
        local test_items, id_map = collect_items(args.tree, discovery)
        if #test_items == 0 then
            vim.notify("neotest-al: no test items found to run", vim.log.levels.WARN)
            return nil
        end

        -- Get launch configuration (may prompt with vim.ui.select)
        local config = launch.get_config(position.path, { launch_json_path = opts.launch_json_path })
        if not config then return nil end

        -- Determine SkipPublish from dirty state
        local workspace_root = vim.fs.normalize(client.root_dir or "")
        local skip_publish   = not dirty.is_dirty(workspace_root)

        -- Execute tests (blocks until al/testRunComplete or timeout)
        local results_path = vim.fn.tempname() .. ".json"
        local success = run.execute(client, config, test_items, results_path, skip_publish)

        -- Update dirty state
        if success and not skip_publish then
            dirty.mark_clean(workspace_root)
        end

        return {
            context = {
                results_path = results_path,
                id_map       = id_map,
            },
        }
    end

    ---@param spec neotest.RunSpec
    ---@param result neotest.StrategyResult
    ---@param tree neotest.Tree
    ---@return table<string, neotest.Result>
    function runner.results(spec, result, tree)
        local f = io.open(spec.context.results_path, "r")
        if not f then return {} end
        local content = f:read("*a")
        f:close()

        local ok, data = pcall(vim.json.decode, content)
        if not ok or not data then return {} end

        -- Set vim diagnostics from build errors
        if data.build_errors and #data.build_errors > 0 then
            diagnostics.set(data.build_errors)
        end

        local output  = table.concat(data.build_log or {}, "")
        local id_map  = spec.context.id_map or {}
        local neotest_results = {}

        -- Build failure: no tests ran, mark everything in the tree as failed
        if #(data.build_errors or {}) > 0 and #(data.tests or {}) == 0 then
            local function mark_failed(node)
                local d = node:data()
                neotest_results[d.id] = {
                    status = "failed",
                    short  = "Build failed — see diagnostics",
                    output = output,
                }
                for _, child in ipairs(node:children() or {}) do
                    mark_failed(child)
                end
            end
            mark_failed(tree)
            return neotest_results
        end

        -- Map individual test results
        local STATUS = { [0] = "passed", [1] = "failed", [2] = "skipped" }
        for _, t in ipairs(data.tests or {}) do
            local key    = tostring(t.codeunit_id) .. ":" .. t.name
            local pos_id = id_map[key]
            if pos_id then
                neotest_results[pos_id] = {
                    status   = STATUS[t.status] or "failed",
                    short    = t.message or "",
                    output   = output,
                    duration = t.duration,
                }
            end
        end

        return neotest_results
    end

    return runner
end

return M
```

- [ ] **Step 4: Run tests to verify they pass**

```
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/neotest-al/runner/lsp/init_spec.lua" +qa
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/neotest-al/runner/lsp/init.lua tests/neotest-al/runner/lsp/init_spec.lua
git commit -m "feat(runner/lsp): add init.lua — build_spec orchestrator and results mapper"
```

---

## Task 7: Replace runner/lsp.lua with backward-compat shim

Replace the placeholder `runner/lsp.lua` with a shim that delegates to `runner/lsp/init.lua`. Update `interfaces_spec.lua` to match the new behavior.

**Files:**
- Modify: `lua/neotest-al/runner/lsp.lua`
- Modify: `tests/neotest-al/interfaces_spec.lua`

- [ ] **Step 1: Update interfaces_spec.lua**

Replace the two placeholder-specific tests in `tests/neotest-al/interfaces_spec.lua` (the `"lsp runner build_spec returns nil and notifies"` and `"lsp runner results returns empty table"` tests) with:

```lua
    it("lsp runner has build_spec and results functions", function()
        local runner = require("neotest-al.runner.lsp")
        assert.is_function(runner.build_spec)
        assert.is_function(runner.results)
    end)
```

The full updated file content:

```lua
describe("interfaces", function()
    it("discovery typedef module loads without error", function()
        assert.has_no.errors(function()
            require("neotest-al.discovery")
        end)
    end)

    it("runner typedef module loads without error", function()
        assert.has_no.errors(function()
            require("neotest-al.runner")
        end)
    end)

    it("lsp runner loads without error", function()
        assert.has_no.errors(function()
            require("neotest-al.runner.lsp")
        end)
    end)

    it("lsp runner has build_spec and results functions", function()
        local runner = require("neotest-al.runner.lsp")
        assert.is_function(runner.build_spec)
        assert.is_function(runner.results)
    end)
end)
```

- [ ] **Step 2: Run interfaces_spec to verify test changes are expected failures**

```
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/neotest-al/interfaces_spec.lua" +qa
```

Expected: `"lsp runner has build_spec and results functions"` FAILS because `lsp.lua` is still the placeholder with `.name = "lsp"` but the new test just checks functions exist — actually it should still PASS since `build_spec` and `results` are functions on the placeholder too. Only the notification test was removed. Verify the suite passes as-is before changing `lsp.lua`.

- [ ] **Step 3: Replace lua/neotest-al/runner/lsp.lua with shim**

```lua
-- Backward-compatibility shim.
-- Provides a default instance of the LSP runner so existing configs that do:
--   require("neotest-al")()   -- uses default runner/lsp
-- continue to work without any changes.
return require("neotest-al.runner.lsp.init").new()
```

- [ ] **Step 4: Run the full test suite**

```
nvim --headless -u tests/minimal_init.lua -c "lua require('plenary.test_harness').test_directory('tests', { minimal_init = 'tests/minimal_init.lua' })" +qa
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/neotest-al/runner/lsp.lua tests/neotest-al/interfaces_spec.lua
git commit -m "feat(runner/lsp): replace placeholder with backward-compat shim to runner/lsp/init"
```

---

## Self-Review Notes

- **spec coverage:** All five design sections mapped to tasks. launch config → Task 2. dirty tracking → Task 3. diagnostics → Task 4. run/notifications → Task 5. orchestration + results → Task 6.
- **type consistency:** `id_map` is `table<string, string>` throughout (`"codeunit_id:test_name" → position_id`). `test_items` are raw LSP objects. `results_path` is a string path. All consistent across Task 5 (run.execute), Task 6 (build_spec / results), and Task 6 tests.
- **no placeholders:** all steps contain actual code.
- **shim backward compat:** `require("neotest-al.runner.lsp")` still works after Task 7 via the shim.
