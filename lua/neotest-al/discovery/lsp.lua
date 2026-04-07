local Tree = require("neotest.types").Tree
local nio = require("nio")

-- ── Windows path normalisation for Tree lookups ───────────────────────────────
--
-- On Windows, neotest's internal tree uses backslash position IDs (produced by
-- lib.files.find with sep="\\"), but its CursorHold handler looks up positions
-- using vim.fn.expand("%:p") which returns forward-slash paths.  The mismatch
-- means get_key misses every time → hover/jump in the summary never works.
--
-- Fix: patch Tree:get_key once at module load to fall back to a backslash-
-- normalised lookup when the exact key isn't found on Windows.  All Tree
-- instances share this method via their metatable, so one patch covers all.
do
    local IS_WIN = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
    if IS_WIN then
        local orig = Tree.get_key
        Tree.get_key = function(self, key)
            local v = orig(self, key)
            if v ~= nil then
                return v
            end
            if type(key) ~= "string" then
                return nil
            end

            -- Fast path: try pure-backslash version (covers the common case where
            -- neotest looks up a forward-slash path against our backslash file keys).
            local bs_key = key:gsub("/", "\\")
            if bs_key ~= key then
                v = orig(self, bs_key)
                if v ~= nil then
                    return v
                end
            end

            -- Normalised key for the remaining two fallbacks.
            local norm = key:gsub("\\", "/"):lower()

            -- _nodes scan: handles mixed-separator dir keys produced by neotest's
            -- parse_dir_from_files (root has "/" while subpath uses "\").
            for k, node in pairs(self._nodes) do
                if type(k) == "string" and k:gsub("\\", "/"):lower() == norm then
                    return node
                end
            end

            -- Structural traversal: last resort for nodes that are reachable via
            -- _children but were never correctly inserted into the shared _nodes
            -- table (happens when neotest's merge wraps trees in empty-path sentinel
            -- nodes on Windows, breaking the _nodes propagation).
            for _, node in self:iter_nodes() do
                local id = node:data().id
                if type(id) == "string" and id:gsub("\\", "/"):lower() == norm then
                    return node
                end
            end
        end
    end
end

---@type neotest-al.Discovery
local M = {}
M.name = "lsp"

-- raw_tree[client_id] = testItems array as pushed by al/updateTests (unprocessed).
-- Processing is deferred until discover_positions/get_items is called for a
-- specific file, so al/updateTests never blocks the UI regardless of project size.
local raw_tree = {}

-- cache[client_id][norm_path] = file_data  (lazily populated from raw_tree)
-- A MISSING sentinel distinguishes "checked, no tests" from "not yet checked".
local cache = {}
local MISSING = {} -- sentinel: file is in the project but has no tests

-- fetch_in_progress[client_id] = true while an al/discoverTests request is in flight.
local fetch_in_progress = {}

-- discover_in_progress[client_id] = true while discover_when_ready is polling.
-- Prevents concurrent callers (LspAttach + al/activeProjectLoaded) from doubling up.
local discover_in_progress = {}

-- test_file_set[client_id] = { [norm_path] = true }
-- Rebuilt from raw_tree whenever raw_tree is updated.
-- Used by is_test_file for O(1) lookup with no file I/O.
local test_file_set = {}

-- true once vim.lsp.rpc.Client.handle_body has been patched at the class level.
local _class_patched = false

-- ── Client patching ──────────────────────────────────────────────────────────
--
-- The AL Language Server sends JSON-RPC responses with `"error": null` alongside
-- a valid `result`. In Neovim's rpc.lua, `if decoded.error then` is truthy for
-- vim.NIL (how JSON null decodes), but `type(vim.NIL) ~= 'table'` triggers
-- `assert(type(decoded.error) == 'table')` at line 452, the callback is never
-- called, and our nio coroutine hangs.
--
-- Fix: patch vim.lsp.rpc.Client.handle_body at the class level (via the
-- metatable) to normalize any truthy non-table error value to nil before
-- Neovim processes it. Applied eagerly at module load and via LspAttach so
-- the fix is in place before the first AL server response arrives.

---@param lsp_client vim.lsp.Client
---@return table|nil
local function get_rpc_client(lsp_client)
    local fn = lsp_client.rpc and lsp_client.rpc.request
    if type(fn) ~= "function" then
        return nil
    end
    for i = 1, 30 do
        local name, val = debug.getupvalue(fn, i)
        if not name then
            break
        end
        if name == "client" then
            return val
        end
    end
end

---@param lsp_client vim.lsp.Client
local function patch_rpc_class(lsp_client)
    if _class_patched then
        return
    end

    local rpc_client = get_rpc_client(lsp_client)
    if not rpc_client then
        return
    end

    local mt = getmetatable(rpc_client)
    if not mt or type(mt.__index) ~= "table" then
        return
    end

    local Client_class = mt.__index
    if type(Client_class.handle_body) ~= "function" then
        return
    end

    local orig = Client_class.handle_body
    _class_patched = true

    function Client_class:handle_body(body)
        local ok, decoded = pcall(vim.json.decode, body, { luanil = { object = true } })
        if ok and type(decoded) == "table" then
            local e = decoded.error
            -- Normalize any truthy non-table error (vim.NIL, string, number…)
            -- so Neovim's assert(type(decoded.error)=='table') doesn't fire.
            if e and type(e) ~= "table" then
                decoded.error = nil
                -- JSON-RPC requires either `result` or `error`. After removing
                -- the invalid error, ensure `result` exists so Neovim doesn't
                -- log INVALID_SERVER_MESSAGE and drop the callback.
                if decoded.result == nil then
                    decoded.result = vim.NIL
                end
                body = vim.json.encode(decoded)
            end
        end
        return orig(self, body)
    end
end

-- Apply patch to any al_ls clients already running when this module loads.
vim.schedule(function()
    for _, c in ipairs(vim.lsp.get_clients({ name = "al_ls" })) do
        patch_rpc_class(c)
        if _class_patched then
            break
        end
    end
end)

-- ── Path normalisation ────────────────────────────────────────────────────────

-- On Windows, drive letters can differ in case between LSP URIs ("file:///c:/")
-- and filesystem paths ("C:/").  Lowercase everything on Windows so all
-- comparisons and cache keys are consistent.
local IS_WINDOWS = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1

---@param path string
---@return string  normalised (and lowercased on Windows)
local function norm(path)
    local n = vim.fs.normalize(path)
    return IS_WINDOWS and n:lower() or n
end

-- ── Client resolution ─────────────────────────────────────────────────────────

---@param path string
---@return vim.lsp.Client|nil
local function find_client(path)
    local np = norm(path)
    local clients = vim.lsp.get_clients({ name = "al_ls" })
    vim.notify(
        ("neotest-al find_client: path=%s clients=%d"):format(np, #clients),
        vim.log.levels.DEBUG,
        { title = "neotest-al" }
    )
    for _, client in ipairs(clients) do
        local root = norm(client.root_dir or "")
        vim.notify(
            ("neotest-al find_client:   root=%s match=%s"):format(
                root,
                tostring(np:sub(1, #root) == root and np:sub(#root + 1, #root + 1) == "/")
            ),
            vim.log.levels.DEBUG,
            { title = "neotest-al" }
        )
        if
            #root > 0
            and (np == root or (np:sub(1, #root) == root and np:sub(#root + 1, #root + 1) == "/"))
        then
            return client
        end
    end
end

-- ── Per-file lazy extraction ──────────────────────────────────────────────────

---@param uri string  e.g. "file:///c:/..."
---@return string     normalised filesystem path
local function uri_to_path(uri)
    return norm(vim.uri_to_fname(uri))
end

-- Scan raw_tree[client_id] once and build a flat set of test file paths.
-- Called every time raw_tree[client_id] is set or replaced so is_test_file
-- stays current without any file I/O.
local function build_test_file_set(client_id)
    local items = raw_tree[client_id]
    if not items then
        test_file_set[client_id] = nil
        return
    end
    local set = {}
    for _, app in ipairs(items) do
        for _, codeunit in ipairs(app.children or {}) do
            for _, test in ipairs(codeunit.children or {}) do
                if test.location and test.location.source then
                    set[uri_to_path(test.location.source)] = true
                end
            end
        end
    end
    test_file_set[client_id] = set
end

-- Build the full file-indexed table from raw testItems — kept for tests and
-- for the index_by_file export.  Not called on hot paths any more.
---@param result table  raw testItems array
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
                            codeunit_id = codeunit.codeunitId,
                            tests = {},
                        }
                    end
                    table.insert(by_file[fpath].tests, test)
                end
            end
        end
    end
    return by_file
end

-- Extract file data for a single path from the raw tree, caching the result.
-- This is the only place uri_to_path is called on a hot path, and it only
-- runs when the user navigates to a test file — never on save.
---@param client_id integer
---@param norm_path string  normalized file path
---@return {codeunit_name:string, codeunit_id:integer, tests:table[]}|nil
local function find_for_path(client_id, norm_path)
    -- norm_path must already be normalised with norm() by the caller
    if not cache[client_id] then
        cache[client_id] = {}
    end
    if cache[client_id][norm_path] ~= nil then
        local v = cache[client_id][norm_path]
        return v ~= MISSING and v or nil
    end

    -- Extract from raw tree (scan once per file, result cached afterward)
    local result = nil
    for _, app in ipairs(raw_tree[client_id] or {}) do
        for _, codeunit in ipairs(app.children or {}) do
            for _, test in ipairs(codeunit.children or {}) do
                if test.location and test.location.source then
                    if uri_to_path(test.location.source) == norm_path then
                        if not result then
                            result = {
                                codeunit_name = codeunit.name,
                                codeunit_id = codeunit.codeunitId,
                                tests = {},
                            }
                        end
                        table.insert(result.tests, test)
                    end
                end
            end
        end
    end

    cache[client_id][norm_path] = result or MISSING
    return result
end

-- ── Cache management ──────────────────────────────────────────────────────────

---@param client_id? integer  nil = clear all workspaces
function M.invalidate(client_id)
    if client_id then
        raw_tree[client_id] = nil
        cache[client_id] = nil
        test_file_set[client_id] = nil
        discover_in_progress[client_id] = nil
    else
        raw_tree = {}
        cache = {}
        fetch_in_progress = {}
        test_file_set = {}
        discover_in_progress = {}
    end
end

-- ── Notification handlers ─────────────────────────────────────────────────────
--
-- al/updateTests is a reactive notification — the server pushes it on init and
-- after reloads.  We treat it as a cache refresh: store the new tree and
-- invalidate the per-file lazy cache.  Primary discovery uses al/discoverTests
-- directly; al/updateTests just keeps the cache current between explicit calls.
-- No uri_to_path calls happen here, so the notification never blocks the UI.

-- Call al/discoverTests immediately and populate raw_tree + test_file_set.
-- Guard prevents concurrent callers (LspAttach + al/activeProjectLoaded) from doubling up.
local function discover_when_ready(client, client_id)
    if discover_in_progress[client_id] then
        return
    end
    if raw_tree[client_id] then
        return
    end
    discover_in_progress[client_id] = true

    client:request("al/discoverTests", {}, function(req_err, response)
        discover_in_progress[client_id] = nil
        if not req_err and type(response) == "table" and #response > 0 then
            vim.schedule(function()
                raw_tree[client_id] = response
                cache[client_id] = nil
                build_test_file_set(client_id)
            end)
        end
    end)
end

local function setup_notification_handlers()
    local prev_update = vim.lsp.handlers["al/updateTests"]
    vim.lsp.handlers["al/updateTests"] = function(err, result, ctx, config)
        if result and result.testItems then
            local client_id = ctx.client_id
            local items = result.testItems
            vim.schedule(function()
                local was_empty = not raw_tree[client_id] or #raw_tree[client_id] == 0
                local now_populated = #items > 0
                vim.notify(
                    ("neotest-al updateTests: items=%d was_empty=%s now_populated=%s"):format(
                        #items,
                        tostring(was_empty),
                        tostring(now_populated)
                    ),
                    vim.log.levels.DEBUG,
                    { title = "neotest-al" }
                )
                raw_tree[client_id] = items
                cache[client_id] = nil -- invalidate lazy per-file cache
                build_test_file_set(client_id)
                -- When transitioning from empty → populated (server finished loading
                -- test data after the closure was ready), re-trigger neotest discovery
                -- for any open AL buffers. The fetch_and_cache retry loop may have
                -- already timed out before the test data arrived.
                if was_empty and now_populated then
                    vim.notify(
                        "neotest-al: updateTests populated, re-triggering discovery",
                        vim.log.levels.DEBUG,
                        { title = "neotest-al" }
                    )
                    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "al" then
                            local fname = vim.api.nvim_buf_get_name(buf)
                            vim.notify(
                                "neotest-al: BufWritePost for " .. fname,
                                vim.log.levels.DEBUG,
                                { title = "neotest-al" }
                            )
                            -- Use pattern= so global autocmds (neotest) fire,
                            -- not just buffer-local ones
                            vim.api.nvim_exec_autocmds("BufWritePost", {
                                pattern = fname,
                                modeline = false,
                            })
                        end
                    end
                end
            end)
        end
        if prev_update then
            prev_update(err, result, ctx, config)
        end
    end

    -- al/projectsLoadedNotification fires once per dependency as the server loads
    -- each workspace (can fire ~30+ times during a multi-project load).  Only
    -- invalidate the cache here — do NOT trigger discovery, because the project
    -- closure is not necessarily fully built yet.  al/activeProjectLoaded fires
    -- once when everything is ready and is the correct trigger for al/discoverTests.
    local prev_loaded = vim.lsp.handlers["al/projectsLoadedNotification"]
    vim.lsp.handlers["al/projectsLoadedNotification"] = function(err, result, ctx, config)
        M.invalidate(ctx.client_id)
        if prev_loaded then
            prev_loaded(err, result, ctx, config)
        end
    end

    -- al/activeProjectLoaded: newer AL LSP versions fire this instead.
    -- No need to invalidate — this fires on initial load, not reload.
    local prev_active = vim.lsp.handlers["al/activeProjectLoaded"]
    vim.lsp.handlers["al/activeProjectLoaded"] = function(err, result, ctx, config)
        local client_id = ctx.client_id
        local client = vim.lsp.get_client_by_id(client_id)
        if client then
            discover_when_ready(client, client_id)
        end
        if prev_active then
            prev_active(err, result, ctx, config)
        end
    end

    -- Apply the handle_body patch when an al_ls client attaches.
    -- Discovery is triggered by al/activeProjectLoaded or al/projectsLoadedNotification
    -- once the project closure is actually ready.
    vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("neotest_al_lsp_patch", { clear = true }),
        callback = function(args)
            local c = vim.lsp.get_client_by_id(args.data.client_id)
            if c and c.name == "al_ls" then
                patch_rpc_class(c)
            end
        end,
    })
end

-- Register immediately so we capture al/updateTests before discover_positions
-- is ever called.
setup_notification_handlers()

-- If al_ls is already running when this module loads (common in lazy-loaded
-- configs), al/updateTests notifications have already fired and been dropped.
-- Trigger discovery now so raw_tree gets populated.
vim.schedule(function()
    for _, c in ipairs(vim.lsp.get_clients({ name = "al_ls" })) do
        patch_rpc_class(c)
        discover_when_ready(c, c.id)
    end
end)

-- ── Fetch from LSP ────────────────────────────────────────────────────────────

---@param client vim.lsp.Client
local function fetch_and_cache(client)
    patch_rpc_class(client)

    while fetch_in_progress[client.id] do
        nio.sleep(20)
    end
    if raw_tree[client.id] then
        return
    end

    fetch_in_progress[client.id] = true

    -- al/discoverTests is the primary data source for discovery.
    -- Retry up to 10 s (50 × 200 ms) in case the server isn't ready yet and
    -- returns an empty response.  al/updateTests may also populate raw_tree
    -- reactively while we wait — bail early if it does.
    local request = nio.wrap(function(cb)
        client:request("al/discoverTests", {}, cb)
    end, 1)
    for _ = 1, 50 do
        if raw_tree[client.id] then
            break -- al/updateTests beat us to it
        end
        local err, result = request()
        if not err and type(result) == "table" and #result > 0 then
            raw_tree[client.id] = result
            cache[client.id] = nil
            build_test_file_set(client.id)
            break
        end
        nio.sleep(200)
    end

    fetch_in_progress[client.id] = nil
end

-- ── discover_positions ────────────────────────────────────────────────────────

---@async
---@param path string
---@return neotest.Tree|nil
function M.discover_positions(path)
    local client = find_client(path)
    if not client then
        return nil
    end

    if not raw_tree[client.id] then
        fetch_and_cache(client)
    end

    if not raw_tree[client.id] then
        return nil
    end

    local file_data = find_for_path(client.id, norm(path))
    if not file_data or #file_data.tests == 0 then
        return nil
    end

    -- On Windows, normalise the path to use backslashes so it matches the paths
    -- neotest produces from lib.files.find (which uses sep = "\\").  Mixed
    -- separators across calls (BufWritePost gives forward-slashes, the directory
    -- walker gives backslashes) would cause neotest to store duplicate position
    -- entries for the same file and trigger redundant directory rescans.
    -- On Windows, neotest's lib.files.find uses sep="\\" so all position IDs in
    -- its internal tree use backslashes.  We match that format so our file nodes
    -- merge correctly and get_position lookups succeed.
    local canonical_path = IS_WINDOWS and path:gsub("/", "\\") or path

    -- Use the last test's end line for the file range.
    -- Avoids a blocking vim.fn.readfile call (which can stall the UI on Windows
    -- when the file is temporarily locked by AV or the AL Language Server).
    local last_test_range = file_data.tests[#file_data.tests].location.range
    local file_end_line = last_test_range["end"].line

    local pos_list = {
        {
            type = "file",
            path = canonical_path,
            name = file_data.codeunit_name,
            id = canonical_path,
            range = { 0, 0, file_end_line, 0 },
        },
    }

    for _, test in ipairs(file_data.tests) do
        local r = test.location.range
        table.insert(pos_list, {
            type = "test",
            path = canonical_path,
            name = test.name,
            id = canonical_path .. "::" .. test.name,
            range = { r.start.line, r.start.character, r["end"].line, r["end"].character },
        })
    end

    -- Yield to the event loop before returning.  When neotest rescans all test
    -- files after a save, it calls discover_positions for every file in rapid
    -- succession.  Because cache hits involve no async operations, all 60 calls
    -- complete synchronously without ever yielding.  neotest queues one
    -- `discover_positions` listener coroutine per file; when the event loop
    -- finally runs them all at once, each one checks `summary.running` (still
    -- false because the render-loop coroutine hasn't started yet) and schedules
    -- its own render loop — resulting in 60 concurrent render loops that
    -- permanently flood the event loop.
    --
    -- A single nio.sleep(0) here yields after each file, giving the event loop
    -- a chance to start the render loop and set `running = true` before the next
    -- listener fires.  All subsequent listeners then just set the render_ready
    -- flag rather than spawning new loops.
    nio.sleep(0)
    return Tree.from_list(pos_list, function(pos)
        return pos.id
    end)
end

--- Returns true if path is known to contain AL tests according to the LSP.
--- Returns false when the LSP hasn't loaded yet (neotest will retry on next scan).
--- No file I/O — O(1) lookup against the pre-built test_file_set.
---@param path string
---@return boolean
function M.is_test_file(path)
    local np = norm(path)
    local total = 0
    for _, file_set in pairs(test_file_set) do
        total = total + vim.tbl_count(file_set)
        if file_set[np] then
            return true
        end
    end
    vim.notify(
        ("neotest-al is_test_file: FALSE path=%s test_file_set has %d entries"):format(np, total),
        vim.log.levels.DEBUG,
        { title = "neotest-al" }
    )
    return false
end

-- ── Test-only exports ─────────────────────────────────────────────────────────
M._find_client = find_client
M._index_by_file = index_by_file
M._norm = norm
M._test_file_set = test_file_set

--- Returns the test entry for a file path, extracting lazily from the raw tree.
--- Used by the LSP runner to get raw LSP test items for al/runTests.
---@param path string  normalized filesystem path
---@return { codeunit_name: string, codeunit_id: integer, tests: table[] }|nil
function M.get_items(path)
    local np = norm(path)
    for client_id in pairs(raw_tree) do
        local data = find_for_path(client_id, np)
        if data then
            return data
        end
    end
end

--- Returns the al_ls client responsible for the given path, or nil.
---@param path string
---@return vim.lsp.Client|nil
function M.get_client(path)
    return find_client(path)
end

return M
