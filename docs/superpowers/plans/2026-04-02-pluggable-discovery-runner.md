# Pluggable Discovery & Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor neotest-al into a pluggable architecture with typed Discovery/Runner interfaces, LSP-based discovery via `al/discoverTests`, and a clean public OSS package free of company-specific code.

**Architecture:** The adapter becomes a thin orchestrator wiring a `Discovery` module (treesitter or lsp) to a `Runner` module (lsp placeholder or third-party). Both interfaces are defined with `@class` typedefs and validated at init time. LSP discovery caches the full workspace test tree from `al/discoverTests` and slices it per-file; the cache invalidates on `al/projectsLoadedNotification` or when the runner explicitly calls `discovery.invalidate()` after a build.

**Tech Stack:** Lua, Neovim LSP (`vim.lsp`), nvim-nio (async), neotest, plenary.nvim (tests), treesitter AL grammar

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `lua/neotest-al/discovery/init.lua` | `@class neotest-al.Discovery` typedef |
| Create | `lua/neotest-al/runner/init.lua` | `@class neotest-al.Runner` typedef |
| Create | `lua/neotest-al/discovery/treesitter.lua` | Treesitter discovery (extracted from adapter.lua) |
| Create | `lua/neotest-al/discovery/lsp.lua` | LSP discovery via `al/discoverTests` |
| Create | `lua/neotest-al/runner/lsp.lua` | Placeholder LSP runner |
| Rewrite | `lua/neotest-al/adapter.lua` | Thin orchestrator with interface validation |
| Modify | `lua/neotest-al/init.lua` | Unchanged shape; defaults now wire to lsp modules |
| Delete | `lua/neotest-al/results.lua` | Moves to private Continia runner repo |
| Create | `tests/minimal_init.lua` | Test bootstrap (rtp + filetype) |
| Create | `tests/fixtures/TestCodeunit.al` | AL fixture with two `[Test]` procedures |
| Create | `tests/neotest-al/discovery/treesitter_spec.lua` | Treesitter discovery tests |
| Create | `tests/neotest-al/discovery/lsp_spec.lua` | LSP discovery tests (sync helpers + async) |
| Create | `tests/neotest-al/adapter_spec.lua` | Adapter validation tests |
| Create | `README.md` | Setup, options, custom runner guide |

---

## Task 1: Test Infrastructure

**Files:**
- Create: `tests/minimal_init.lua`
- Create: `tests/fixtures/TestCodeunit.al`

- [ ] **Step 1: Create `tests/minimal_init.lua`**

```lua
-- tests/minimal_init.lua
vim.opt.rtp:prepend(".")

local lazy = vim.fn.stdpath("data") .. "/lazy"
for _, dep in ipairs({ "plenary.nvim", "nvim-nio", "neotest", "nvim-treesitter" }) do
    vim.opt.rtp:prepend(lazy .. "/" .. dep)
end

vim.filetype.add({ extension = { al = "al" } })
```

- [ ] **Step 2: Create `tests/fixtures/TestCodeunit.al`**

```al
codeunit 50100 "My Test Codeunit"
{
    Subtype = Test;

    [Test]
    procedure Test_WhenX_ShouldY()
    begin
    end;

    [Test]
    procedure AnotherTest_WhenA_ShouldB()
    begin
    end;

    local procedure HelperProcedure()
    begin
    end;
}
```

- [ ] **Step 3: Write a hello-world smoke test at `tests/smoke_spec.lua`**

```lua
describe("smoke", function()
    it("loads neotest-al without error", function()
        assert.has_no.errors(function()
            require("neotest-al")
        end)
    end)
end)
```

- [ ] **Step 4: Run smoke test to confirm infrastructure works**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests/', {minimal_init='tests/minimal_init.lua', sequential=true})" \
  -c "qa!"
```

Expected: `1 success` (smoke test passes). If neotest-al loads, the rtp is wired correctly.

- [ ] **Step 5: Commit**

```bash
git add tests/minimal_init.lua tests/fixtures/TestCodeunit.al tests/smoke_spec.lua
git commit -m "test: add test infrastructure and AL fixture"
```

---

## Task 2: Interface Typedefs

**Files:**
- Create: `lua/neotest-al/discovery/init.lua`
- Create: `lua/neotest-al/runner/init.lua`

- [ ] **Step 1: Write failing test at `tests/neotest-al/interfaces_spec.lua`**

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
end)
```

- [ ] **Step 2: Run to confirm failure**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests/', {minimal_init='tests/minimal_init.lua', sequential=true})" \
  -c "qa!"
```

Expected: 2 failures — `module 'neotest-al.discovery' not found`.

- [ ] **Step 3: Create `lua/neotest-al/discovery/init.lua`**

```lua
---@class neotest-al.Discovery
---@field name string                                                          -- display name, e.g. "lsp", "treesitter"
---@field discover_positions fun(path: string): neotest.Tree|nil              -- async (runs in nio coroutine)
---@field invalidate fun(client_id?: integer): nil                            -- nil clears all workspaces
```

- [ ] **Step 4: Create `lua/neotest-al/runner/init.lua`**

```lua
---@class neotest-al.Runner
---@field name string
---@field build_spec fun(args: neotest.RunArgs, discovery: neotest-al.Discovery): neotest.RunSpec|nil
---@field results   fun(spec: neotest.RunSpec, result: neotest.StrategyResult, tree: neotest.Tree): table<string, neotest.Result>
```

- [ ] **Step 5: Run to confirm tests pass**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests/', {minimal_init='tests/minimal_init.lua', sequential=true})" \
  -c "qa!"
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lua/neotest-al/discovery/init.lua lua/neotest-al/runner/init.lua tests/neotest-al/interfaces_spec.lua
git commit -m "feat: add Discovery and Runner interface typedefs"
```

---

## Task 3: Extract Treesitter Discovery

**Files:**
- Create: `lua/neotest-al/discovery/treesitter.lua`
- Create: `tests/neotest-al/discovery/treesitter_spec.lua`

- [ ] **Step 1: Write failing tests at `tests/neotest-al/discovery/treesitter_spec.lua`**

```lua
local treesitter = require("neotest-al.discovery.treesitter")
local fixture_path = vim.fn.fnamemodify("tests/fixtures/TestCodeunit.al", ":p")

describe("neotest-al.discovery.treesitter", function()
    describe("discover_positions", function()
        it("returns a Tree for a test file", function()
            local tree = treesitter.discover_positions(fixture_path)
            assert.is_not_nil(tree)
        end)

        it("root node is type=file with the codeunit name", function()
            local tree = treesitter.discover_positions(fixture_path)
            local root = tree:data()
            assert.are.equal("file", root.type)
            assert.are.equal("My Test Codeunit", root.name)
        end)

        it("finds exactly two test procedures", function()
            local tree = treesitter.discover_positions(fixture_path)
            assert.are.equal(2, #tree:children())
        end)

        it("test node names match [Test] procedure names", function()
            local tree = treesitter.discover_positions(fixture_path)
            local names = vim.tbl_map(function(c) return c:data().name end, tree:children())
            assert.is_truthy(vim.tbl_contains(names, "Test_WhenX_ShouldY"))
            assert.is_truthy(vim.tbl_contains(names, "AnotherTest_WhenA_ShouldB"))
        end)

        it("does not include non-[Test] procedures", function()
            local tree = treesitter.discover_positions(fixture_path)
            local names = vim.tbl_map(function(c) return c:data().name end, tree:children())
            assert.is_falsy(vim.tbl_contains(names, "HelperProcedure"))
        end)

        it("test node id is path::name", function()
            local tree = treesitter.discover_positions(fixture_path)
            local node = tree:children()[1]:data()
            assert.are.equal(fixture_path .. "::" .. node.name, node.id)
        end)
    end)

    describe("invalidate", function()
        it("is a no-op and never errors", function()
            assert.has_no.errors(function()
                treesitter.invalidate(1)
                treesitter.invalidate(nil)
                treesitter.invalidate()
            end)
        end)
    end)
end)
```

- [ ] **Step 2: Run to confirm failure**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests/', {minimal_init='tests/minimal_init.lua', sequential=true})" \
  -c "qa!"
```

Expected: 7 failures — `module 'neotest-al.discovery.treesitter' not found`.

- [ ] **Step 3: Create `lua/neotest-al/discovery/treesitter.lua`**

Extract the existing logic from `adapter.lua` verbatim, adding `name`, `invalidate`, and wrapping in a module:

```lua
local lib = require("neotest.lib")
local Tree = require("neotest.types").Tree

local M = {}
M.name = "treesitter"

local QUERY = [[
    (_
      (attribute_item)*
      .
      (attribute_item
        attribute: (attribute_content
          name: (identifier) @_attr (#eq? @_attr "Test")))
      .
      (attribute_item)*
      .
      (procedure
        name: (identifier) @test.name) @test.definition
    )
]]

---@async
---@param path string
---@return neotest.Tree|nil
function M.discover_positions(path)
    local content = lib.files.read(path)
    local lines = vim.split(content, "\n")

    local parser = vim.treesitter.get_string_parser(content, "al")
    local parsed_tree = parser:parse()[1]
    local root = parsed_tree:root()

    local query = vim.treesitter.query.parse("al", QUERY)

    local name_id, def_id
    for id, name in ipairs(query.captures) do
        if name == "test.name" then name_id = id end
        if name == "test.definition" then def_id = id end
    end

    local codeunit_name = content:match('[Cc]odeunit%s+%d+%s+"([^"]+)"')
        or content:match("[Cc]odeunit%s+%d+%s+([%w_%.%-]+)")

    local pos_list = {
        {
            type  = "file",
            path  = path,
            name  = codeunit_name or vim.fn.fnamemodify(path, ":t"),
            id    = path,
            range = { 0, 0, #lines - 1, 0 },
        },
    }

    local seen = {}
    for _, match in query:iter_matches(root, content, 0, -1, { all = true }) do
        local name_nodes = match[name_id]
        local def_nodes  = match[def_id]
        if name_nodes and def_nodes then
            local name_node = type(name_nodes) == "table" and name_nodes[1] or name_nodes
            local def_node  = type(def_nodes)  == "table" and def_nodes[1]  or def_nodes
            local sr, sc, er, ec = def_node:range()
            if not seen[sr] then
                seen[sr] = true
                local test_name = vim.treesitter.get_node_text(name_node, content)
                table.insert(pos_list, {
                    type  = "test",
                    path  = path,
                    name  = test_name,
                    id    = path .. "::" .. test_name,
                    range = { sr, sc, er, ec },
                })
            end
        end
    end

    return Tree.from_list(pos_list, function(pos) return pos.id end)
end

---@param _client_id? integer  unused — treesitter has no cache
function M.invalidate(_client_id)
    -- no-op
end

return M
```

- [ ] **Step 4: Run to confirm tests pass**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests/', {minimal_init='tests/minimal_init.lua', sequential=true})" \
  -c "qa!"
```

Expected: all 7 new tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/neotest-al/discovery/treesitter.lua tests/neotest-al/discovery/treesitter_spec.lua
git commit -m "feat: extract treesitter discovery into neotest-al.discovery.treesitter"
```

---

## Task 4: LSP Discovery — Skeleton (client resolution, cache, invalidate)

**Files:**
- Create: `lua/neotest-al/discovery/lsp.lua` (skeleton only — no fetch yet)
- Create: `tests/neotest-al/discovery/lsp_spec.lua`

- [ ] **Step 1: Write failing tests at `tests/neotest-al/discovery/lsp_spec.lua`**

```lua
describe("neotest-al.discovery.lsp", function()
    local lsp

    before_each(function()
        package.loaded["neotest-al.discovery.lsp"] = nil
        lsp = require("neotest-al.discovery.lsp")
    end)

    -- ── _find_client ──────────────────────────────────────────────────────────
    describe("_find_client", function()
        it("returns nil when no al_ls clients exist", function()
            local orig = vim.lsp.get_clients
            vim.lsp.get_clients = function() return {} end

            assert.is_nil(lsp._find_client("/workspace/File.al"))

            vim.lsp.get_clients = orig
        end)

        it("returns client whose root_dir is a prefix of the path", function()
            local mock = { id = 1, root_dir = "/workspace", name = "al_ls" }
            local orig = vim.lsp.get_clients
            vim.lsp.get_clients = function() return { mock } end

            assert.are.equal(mock, lsp._find_client("/workspace/Src/File.al"))

            vim.lsp.get_clients = orig
        end)

        it("returns nil when path is outside all client root_dirs", function()
            local mock = { id = 1, root_dir = "/workspace", name = "al_ls" }
            local orig = vim.lsp.get_clients
            vim.lsp.get_clients = function() return { mock } end

            assert.is_nil(lsp._find_client("/other/File.al"))

            vim.lsp.get_clients = orig
        end)
    end)

    -- ── _index_by_file ────────────────────────────────────────────────────────
    describe("_index_by_file", function()
        local function make_response(file_uri)
            return {
                {
                    name = "Test App",
                    children = {
                        {
                            name       = "My Test Codeunit",
                            codeunitId = 50100,
                            children   = {
                                {
                                    name     = "Test_ShouldPass",
                                    location = {
                                        source = file_uri,
                                        range  = {
                                            start  = { line = 5, character = 14 },
                                            ["end"] = { line = 5, character = 28 },
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            }
        end

        it("groups tests under their normalized file path", function()
            local uri   = "file:///workspace/File.al"
            local fpath = vim.fs.normalize(vim.uri_to_fname(uri))
            local result = lsp._index_by_file(make_response(uri))

            assert.is_not_nil(result[fpath])
            assert.are.equal("My Test Codeunit", result[fpath].codeunit_name)
            assert.are.equal(50100, result[fpath].codeunit_id)
            assert.are.equal(1, #result[fpath].tests)
            assert.are.equal("Test_ShouldPass", result[fpath].tests[1].name)
        end)

        it("returns empty table for nil/empty input", function()
            assert.are.same({}, lsp._index_by_file(nil))
            assert.are.same({}, lsp._index_by_file({}))
        end)
    end)

    -- ── invalidate ────────────────────────────────────────────────────────────
    describe("invalidate", function()
        it("clears a specific client's cache without error", function()
            assert.has_no.errors(function() lsp.invalidate(42) end)
        end)

        it("clears all cache when called without arguments", function()
            assert.has_no.errors(function() lsp.invalidate() end)
        end)
    end)
end)
```

- [ ] **Step 2: Run to confirm failure**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests/', {minimal_init='tests/minimal_init.lua', sequential=true})" \
  -c "qa!"
```

Expected: failures — `module 'neotest-al.discovery.lsp' not found`.

- [ ] **Step 3: Create `lua/neotest-al/discovery/lsp.lua` skeleton**

```lua
local lib = require("neotest.lib")
local Tree = require("neotest.types").Tree
local nio  = require("nio")

local M = {}
M.name = "lsp"

-- cache[client_id] = { [norm_file_path] = { codeunit_name, codeunit_id, tests[] } }
local cache = {}

-- ── Client resolution ─────────────────────────────────────────────────────────

---@param path string
---@return vim.lsp.Client|nil
local function find_client(path)
    local norm = vim.fs.normalize(path)
    for _, client in ipairs(vim.lsp.get_clients({ name = "al_ls" })) do
        local root = vim.fs.normalize(client.root_dir or "")
        if #root > 0 and norm:sub(1, #root) == root then
            return client
        end
    end
end

-- ── Response indexing ─────────────────────────────────────────────────────────

---@param uri string  e.g. "file:///c:/..."
---@return string     normalized filesystem path
local function uri_to_path(uri)
    return vim.fs.normalize(vim.uri_to_fname(uri))
end

---@param result table  raw al/discoverTests response (array of app nodes)
---@return table<string, {codeunit_name:string, codeunit_id:integer, tests:table[]}>
local function index_by_file(result)
    local by_file = {}
    for _, app in ipairs(result or {}) do
        for _, codeunit in ipairs(app.children or {}) do
            for _, test in ipairs(codeunit.children or {}) do
                if test.location and test.location.source then
                    local fpath = uri_to_path(test.location.source)
                    if not by_file[fpath] then
                        by_file[fpath] = {
                            codeunit_name = codeunit.name,
                            codeunit_id   = codeunit.codeunitId,
                            tests         = {},
                        }
                    end
                    table.insert(by_file[fpath].tests, test)
                end
            end
        end
    end
    return by_file
end

-- ── Cache management ──────────────────────────────────────────────────────────

---@param client_id? integer  nil = clear all workspaces
function M.invalidate(client_id)
    if client_id then
        cache[client_id] = nil
    else
        cache = {}
    end
end

-- ── Notification handler (invalidate on project reload) ───────────────────────

local _handler_registered = false
local function ensure_notification_handler()
    if _handler_registered then return end
    _handler_registered = true

    local existing = vim.lsp.handlers["al/projectsLoadedNotification"]
    vim.lsp.handlers["al/projectsLoadedNotification"] = function(err, result, ctx, config)
        M.invalidate(ctx.client_id)
        if existing then existing(err, result, ctx, config) end
    end
end

-- ── discover_positions (stub — fetch not yet implemented) ─────────────────────

---@async
---@param path string
---@return neotest.Tree|nil
function M.discover_positions(path)
    ensure_notification_handler()
    local client = find_client(path)
    if not client then return nil end
    -- fetch + Tree building added in next task
    return nil
end

-- ── Test-only exports ─────────────────────────────────────────────────────────
M._find_client  = find_client
M._index_by_file = index_by_file

return M
```

- [ ] **Step 4: Run to confirm tests pass**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests/', {minimal_init='tests/minimal_init.lua', sequential=true})" \
  -c "qa!"
```

Expected: all skeleton tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/neotest-al/discovery/lsp.lua tests/neotest-al/discovery/lsp_spec.lua
git commit -m "feat: add LSP discovery skeleton with client resolution, cache and invalidation"
```

---

## Task 5: LSP Discovery — Fetch and `discover_positions`

**Files:**
- Modify: `lua/neotest-al/discovery/lsp.lua`
- Modify: `tests/neotest-al/discovery/lsp_spec.lua`

- [ ] **Step 1: Append async tests to `tests/neotest-al/discovery/lsp_spec.lua`**

Add these inside the top-level `describe` block, after the `invalidate` tests:

```lua
    -- ── discover_positions ────────────────────────────────────────────────────
    describe("discover_positions", function()
        local async = require("plenary.async")
        local fixture_path = vim.fn.fnamemodify("tests/fixtures/TestCodeunit.al", ":p")
        local fixture_uri  = vim.uri_from_fname(fixture_path)

        local function make_mock_client(id, root, response)
            return {
                id       = id,
                root_dir = root,
                request  = function(self, method, params, cb)
                    cb(nil, response)
                    return true, 1
                end,
            }
        end

        local function mock_response(uri)
            return {
                {
                    name     = "Test App",
                    children = {
                        {
                            name       = "My Test Codeunit",
                            codeunitId = 50100,
                            children   = {
                                {
                                    name     = "Test_WhenX_ShouldY",
                                    location = {
                                        source  = uri,
                                        range   = {
                                            start   = { line = 5, character = 14 },
                                            ["end"] = { line = 5, character = 28 },
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            }
        end

        it("returns nil when no al_ls client exists", async.void(function()
            local orig = vim.lsp.get_clients
            vim.lsp.get_clients = function() return {} end

            local result = lsp.discover_positions(fixture_path)
            assert.is_nil(result)

            vim.lsp.get_clients = orig
        end))

        it("returns nil when LSP has no tests for the file", async.void(function()
            local root   = vim.fn.fnamemodify("tests/fixtures", ":p")
            local client = make_mock_client(88, root, {})  -- empty app list
            local orig   = vim.lsp.get_clients
            vim.lsp.get_clients = function() return { client } end

            local result = lsp.discover_positions(fixture_path)
            assert.is_nil(result)

            vim.lsp.get_clients = orig
            lsp.invalidate(88)
        end))

        it("returns a Tree when LSP reports tests for the file", async.void(function()
            local root   = vim.fn.fnamemodify("tests/fixtures", ":p")
            local client = make_mock_client(99, root, mock_response(fixture_uri))
            local orig   = vim.lsp.get_clients
            vim.lsp.get_clients = function() return { client } end

            local tree = lsp.discover_positions(fixture_path)

            vim.lsp.get_clients = orig
            lsp.invalidate(99)

            assert.is_not_nil(tree)
            local root_node = tree:data()
            assert.are.equal("file", root_node.type)
            assert.are.equal("My Test Codeunit", root_node.name)
        end))

        it("builds one test child per LSP test item", async.void(function()
            local root   = vim.fn.fnamemodify("tests/fixtures", ":p")
            local client = make_mock_client(100, root, mock_response(fixture_uri))
            local orig   = vim.lsp.get_clients
            vim.lsp.get_clients = function() return { client } end

            local tree = lsp.discover_positions(fixture_path)

            vim.lsp.get_clients = orig
            lsp.invalidate(100)

            assert.are.equal(1, #tree:children())
            local test_node = tree:children()[1]:data()
            assert.are.equal("test", test_node.type)
            assert.are.equal("Test_WhenX_ShouldY", test_node.name)
            assert.are.equal(fixture_path .. "::" .. "Test_WhenX_ShouldY", test_node.id)
            assert.are.same({ 5, 14, 5, 28 }, test_node.range)
        end))

        it("serves subsequent calls from cache without re-requesting", async.void(function()
            local request_count = 0
            local root = vim.fn.fnamemodify("tests/fixtures", ":p")
            local client = {
                id       = 101,
                root_dir = root,
                request  = function(self, method, params, cb)
                    request_count = request_count + 1
                    cb(nil, mock_response(fixture_uri))
                    return true, 1
                end,
            }
            local orig = vim.lsp.get_clients
            vim.lsp.get_clients = function() return { client } end

            lsp.discover_positions(fixture_path)
            lsp.discover_positions(fixture_path)

            vim.lsp.get_clients = orig
            lsp.invalidate(101)

            assert.are.equal(1, request_count)
        end))

        it("re-fetches after invalidate", async.void(function()
            local request_count = 0
            local root = vim.fn.fnamemodify("tests/fixtures", ":p")
            local client = {
                id       = 102,
                root_dir = root,
                request  = function(self, method, params, cb)
                    request_count = request_count + 1
                    cb(nil, mock_response(fixture_uri))
                    return true, 1
                end,
            }
            local orig = vim.lsp.get_clients
            vim.lsp.get_clients = function() return { client } end

            lsp.discover_positions(fixture_path)
            lsp.invalidate(102)
            lsp.discover_positions(fixture_path)

            vim.lsp.get_clients = orig
            lsp.invalidate(102)

            assert.are.equal(2, request_count)
        end))
    end)
```

- [ ] **Step 2: Run to confirm new tests fail**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests/', {minimal_init='tests/minimal_init.lua', sequential=true})" \
  -c "qa!"
```

Expected: 6 new failures from `discover_positions` tests (stub returns nil always).

- [ ] **Step 3: Implement `fetch_and_cache` and complete `discover_positions` in `lua/neotest-al/discovery/lsp.lua`**

Replace the stub `discover_positions` and add `fetch_and_cache` above it:

```lua
-- ── Fetch from LSP ────────────────────────────────────────────────────────────

---@param client vim.lsp.Client
---@return table<string, any>
local function fetch_and_cache(client)
    local request = nio.wrap(function(cb)
        client:request("al/discoverTests", {}, cb)
    end, 1)
    local err, result = request()
    if err then
        vim.notify(
            "neotest-al: al/discoverTests failed: " .. vim.inspect(err),
            vim.log.levels.ERROR
        )
        return {}
    end
    return index_by_file(result)
end

-- ── discover_positions ────────────────────────────────────────────────────────

---@async
---@param path string
---@return neotest.Tree|nil
function M.discover_positions(path)
    ensure_notification_handler()

    local client = find_client(path)
    if not client then return nil end

    if not cache[client.id] then
        cache[client.id] = fetch_and_cache(client)
    end

    local norm      = vim.fs.normalize(path)
    local file_data = cache[client.id][norm]
    if not file_data or #file_data.tests == 0 then
        return nil
    end

    local content = lib.files.read(path)
    local lines   = vim.split(content, "\n")

    local pos_list = {
        {
            type  = "file",
            path  = path,
            name  = file_data.codeunit_name,
            id    = path,
            range = { 0, 0, #lines - 1, 0 },
        },
    }

    for _, test in ipairs(file_data.tests) do
        local r = test.location.range
        table.insert(pos_list, {
            type  = "test",
            path  = path,
            name  = test.name,
            id    = path .. "::" .. test.name,
            range = { r.start.line, r.start.character, r["end"].line, r["end"].character },
        })
    end

    return Tree.from_list(pos_list, function(pos) return pos.id end)
end
```

- [ ] **Step 4: Run to confirm all tests pass**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests/', {minimal_init='tests/minimal_init.lua', sequential=true})" \
  -c "qa!"
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/neotest-al/discovery/lsp.lua tests/neotest-al/discovery/lsp_spec.lua
git commit -m "feat: implement LSP discovery fetch and discover_positions"
```

---

## Task 6: LSP Runner Placeholder

**Files:**
- Create: `lua/neotest-al/runner/lsp.lua`

- [ ] **Step 1: Write failing test — append to `tests/neotest-al/interfaces_spec.lua`**

```lua
    it("lsp runner loads without error", function()
        assert.has_no.errors(function()
            require("neotest-al.runner.lsp")
        end)
    end)

    it("lsp runner build_spec returns nil and notifies", function()
        local notified = false
        local orig = vim.notify
        vim.notify = function(msg, level)
            if msg:match("LSP runner is not yet implemented") then
                notified = true
            end
        end

        local runner = require("neotest-al.runner.lsp")
        local result = runner.build_spec({}, {})
        vim.notify = orig

        assert.is_nil(result)
        assert.is_true(notified)
    end)

    it("lsp runner results returns empty table", function()
        local runner = require("neotest-al.runner.lsp")
        assert.are.same({}, runner.results({}, {}, {}))
    end)
```

- [ ] **Step 2: Run to confirm failure**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests/', {minimal_init='tests/minimal_init.lua', sequential=true})" \
  -c "qa!"
```

Expected: 3 failures — `module 'neotest-al.runner.lsp' not found`.

- [ ] **Step 3: Create `lua/neotest-al/runner/lsp.lua`**

```lua
local M = {}
M.name = "lsp"

---@param args neotest.RunArgs
---@param discovery neotest-al.Discovery
---@return neotest.RunSpec|nil
function M.build_spec(args, discovery)
    vim.notify(
        "neotest-al: LSP runner is not yet implemented. "
            .. "Configure a runner in your neotest-al setup.",
        vim.log.levels.WARN
    )
    return nil
end

---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result>
function M.results(spec, result, tree)
    return {}
end

return M
```

- [ ] **Step 4: Run to confirm tests pass**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests/', {minimal_init='tests/minimal_init.lua', sequential=true})" \
  -c "qa!"
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/neotest-al/runner/lsp.lua tests/neotest-al/interfaces_spec.lua
git commit -m "feat: add LSP runner placeholder"
```

---

## Task 7: Refactor Adapter

**Files:**
- Rewrite: `lua/neotest-al/adapter.lua`
- Create: `tests/neotest-al/adapter_spec.lua`

- [ ] **Step 1: Write failing tests at `tests/neotest-al/adapter_spec.lua`**

```lua
describe("neotest-al.adapter", function()
    local create_adapter

    before_each(function()
        package.loaded["neotest-al.adapter"] = nil
        create_adapter = require("neotest-al.adapter")
    end)

    local function stub_discovery(overrides)
        return vim.tbl_extend("force", {
            name              = "stub",
            discover_positions = function() end,
            invalidate        = function() end,
        }, overrides or {})
    end

    local function stub_runner(overrides)
        return vim.tbl_extend("force", {
            name       = "stub",
            build_spec = function() end,
            results    = function() end,
        }, overrides or {})
    end

    -- ── Validation ────────────────────────────────────────────────────────────
    it("raises when discovery is missing discover_positions", function()
        assert.has_error(function()
            create_adapter({
                discovery = stub_discovery({ discover_positions = nil }),
                runner    = stub_runner(),
            })
        end, "neotest-al: discovery must implement discover_positions(path)")
    end)

    it("raises when discovery is missing invalidate", function()
        assert.has_error(function()
            create_adapter({
                discovery = stub_discovery({ invalidate = nil }),
                runner    = stub_runner(),
            })
        end, "neotest-al: discovery must implement invalidate(client_id?)")
    end)

    it("raises when runner is missing build_spec", function()
        assert.has_error(function()
            create_adapter({
                discovery = stub_discovery(),
                runner    = stub_runner({ build_spec = nil }),
            })
        end, "neotest-al: runner must implement build_spec(args, discovery)")
    end)

    it("raises when runner is missing results", function()
        assert.has_error(function()
            create_adapter({
                discovery = stub_discovery(),
                runner    = stub_runner({ results = nil }),
            })
        end, "neotest-al: runner must implement results(spec, result, tree)")
    end)

    -- ── Happy path ────────────────────────────────────────────────────────────
    it("returns a neotest adapter table with required fields", function()
        local adapter = create_adapter({
            discovery = stub_discovery(),
            runner    = stub_runner(),
        })
        assert.are.equal("neotest-al", adapter.name)
        assert.is_function(adapter.discover_positions)
        assert.is_function(adapter.build_spec)
        assert.is_function(adapter.results)
        assert.is_function(adapter.is_test_file)
        assert.is_not_nil(adapter.root)
    end)

    it("passes discovery as second arg to runner.build_spec", function()
        local received = nil
        local discovery = stub_discovery()
        local runner = stub_runner({
            build_spec = function(args, disc)
                received = disc
                return nil
            end,
        })

        local adapter = create_adapter({ discovery = discovery, runner = runner })
        -- Minimal args.tree stub
        local args = {
            tree = setmetatable({}, {
                __index = { data = function() return { type = "test", path = "" } end },
            }),
        }
        adapter.build_spec(args)

        assert.are.equal(discovery, received)
    end)
end)
```

- [ ] **Step 2: Run to confirm tests fail**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests/', {minimal_init='tests/minimal_init.lua', sequential=true})" \
  -c "qa!"
```

Expected: failures because old `adapter.lua` has no validation and wrong signatures.

- [ ] **Step 3: Rewrite `lua/neotest-al/adapter.lua`**

```lua
local lib  = require("neotest.lib")
local base = require("neotest-al.base")

---@param config? { discovery?: neotest-al.Discovery, runner?: neotest-al.Runner }
---@return neotest.Adapter
return function(config)
    config = config or {}

    local discovery = config.discovery or require("neotest-al.discovery.lsp")
    local runner    = config.runner    or require("neotest-al.runner.lsp")

    assert(
        type(discovery.discover_positions) == "function",
        "neotest-al: discovery must implement discover_positions(path)"
    )
    assert(
        type(discovery.invalidate) == "function",
        "neotest-al: discovery must implement invalidate(client_id?)"
    )
    assert(
        type(runner.build_spec) == "function",
        "neotest-al: runner must implement build_spec(args, discovery)"
    )
    assert(
        type(runner.results) == "function",
        "neotest-al: runner must implement results(spec, result, tree)"
    )

    ---@type neotest.Adapter
    return {
        name = "neotest-al",
        root = lib.files.match_root_pattern(".alpackages", "app.json"),

        is_test_file = base.is_test_file,

        ---@async
        discover_positions = function(path)
            return discovery.discover_positions(path)
        end,

        build_spec = function(args)
            return runner.build_spec(args, discovery)
        end,

        results = function(spec, result, tree)
            return runner.results(spec, result, tree)
        end,
    }
end
```

- [ ] **Step 4: Run to confirm all tests pass**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests/', {minimal_init='tests/minimal_init.lua', sequential=true})" \
  -c "qa!"
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/neotest-al/adapter.lua tests/neotest-al/adapter_spec.lua
git commit -m "feat: refactor adapter as thin orchestrator with pluggable discovery and runner"
```

---

## Task 8: Cleanup — Remove `results.lua`, Verify `init.lua`

**Files:**
- Delete: `lua/neotest-al/results.lua`
- Verify: `lua/neotest-al/init.lua` (should need no changes)

- [ ] **Step 1: Confirm `init.lua` does not reference `results.lua`**

Open `lua/neotest-al/init.lua`. It should only contain:

```lua
local create_adapter = require("neotest-al.adapter")

local ALNeotestAdapter = create_adapter({})

setmetatable(ALNeotestAdapter, {
    __call = function(_, opts)
        opts = opts or {}
        return create_adapter(opts)
    end,
})

ALNeotestAdapter.setup = function(opts)
    return ALNeotestAdapter(opts)
end

return ALNeotestAdapter
```

If it contains any reference to `results`, remove it. The file above requires no changes.

- [ ] **Step 2: Delete `lua/neotest-al/results.lua`**

```bash
rm lua/neotest-al/results.lua
```

- [ ] **Step 3: Run full test suite to confirm nothing broke**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests/', {minimal_init='tests/minimal_init.lua', sequential=true})" \
  -c "qa!"
```

Expected: all tests still pass.

- [ ] **Step 4: Commit**

```bash
git add -u
git commit -m "chore: remove results.lua (moved to private Continia runner repo)"
```

---

## Task 9: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`**

```markdown
# neotest-al

A [neotest](https://github.com/nvim-neotest/neotest) adapter for the AL language (Microsoft Dynamics 365 Business Central).

## Requirements

- Neovim ≥ 0.10
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
- If [al.nvim](https://github.com/your-org/al.nvim) is installed, neotest-al will reuse its notification handler infrastructure; otherwise it registers a global `vim.lsp.handlers` entry directly.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with setup, discovery/runner options, and custom runner guide"
```

---

## Self-Review

**Spec coverage check:**
- ✅ Pluggable discovery: Tasks 3–5
- ✅ Pluggable runner: Task 6
- ✅ Typed interfaces: Task 2
- ✅ Adapter validation + defaults: Task 7
- ✅ LSP discovery internals (cache, invalidation, notification handler): Task 4–5
- ✅ `results.lua` removed: Task 8
- ✅ README: Task 9

**Placeholder scan:** No TBDs. All steps contain complete code.

**Type consistency:**
- `discovery.discover_positions(path)` — consistent across Tasks 2, 3, 4, 5, 7
- `discovery.invalidate(client_id?)` — consistent across Tasks 2, 4, 5, 7
- `runner.build_spec(args, discovery)` — consistent across Tasks 2, 6, 7
- `runner.results(spec, result, tree)` — consistent across Tasks 2, 6, 7
- `M._find_client` / `M._index_by_file` — test-only exports defined in Task 4, used in Task 4 tests
