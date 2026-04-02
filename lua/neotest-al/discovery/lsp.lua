local Tree = require("neotest.types").Tree
local nio  = require("nio")

---@type neotest-al.Discovery
local M = {}
M.name = "lsp"

-- raw_tree[client_id] = testItems array as pushed by al/updateTests (unprocessed).
-- Processing is deferred until discover_positions/get_items is called for a
-- specific file, so al/updateTests never blocks the UI regardless of project size.
local raw_tree = {}

-- cache[client_id][norm_path] = file_data  (lazily populated from raw_tree)
-- A MISSING sentinel distinguishes "checked, no tests" from "not yet checked".
local cache   = {}
local MISSING = {}  -- sentinel: file is in the project but has no tests

-- fetch_in_progress[client_id] = true while an al/discoverTests request is in flight.
local fetch_in_progress = {}

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
    if type(fn) ~= "function" then return nil end
    for i = 1, 30 do
        local name, val = debug.getupvalue(fn, i)
        if not name then break end
        if name == "client" then return val end
    end
end

---@param lsp_client vim.lsp.Client
local function patch_rpc_class(lsp_client)
    if _class_patched then return end

    local rpc_client = get_rpc_client(lsp_client)
    if not rpc_client then return end

    local mt = getmetatable(rpc_client)
    if not mt or type(mt.__index) ~= "table" then return end

    local Client_class = mt.__index
    if type(Client_class.handle_body) ~= "function" then return end

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
        if _class_patched then break end
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
    for _, client in ipairs(vim.lsp.get_clients({ name = "al_ls" })) do
        local root = norm(client.root_dir or "")
        if #root > 0 and np:sub(1, #root) == root and np:sub(#root + 1, #root + 1) == "/" then
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

-- Extract file data for a single path from the raw tree, caching the result.
-- This is the only place uri_to_path is called on a hot path, and it only
-- runs when the user navigates to a test file — never on save.
---@param client_id integer
---@param norm_path string  normalized file path
---@return {codeunit_name:string, codeunit_id:integer, tests:table[]}|nil
local function find_for_path(client_id, norm_path)
    -- norm_path must already be normalised with norm() by the caller
    if not cache[client_id] then cache[client_id] = {} end
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
                                codeunit_id   = codeunit.codeunitId,
                                tests         = {},
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
        raw_tree[client_id]      = nil
        cache[client_id]         = nil
        test_file_set[client_id] = nil
    else
        raw_tree          = {}
        cache             = {}
        fetch_in_progress = {}
        test_file_set     = {}
    end
end

-- ── Notification handlers ─────────────────────────────────────────────────────
--
-- al/updateTests is a reactive notification — the server pushes it on init and
-- after reloads.  We treat it as a cache refresh: store the new tree and
-- invalidate the per-file lazy cache.  Primary discovery uses al/discoverTests
-- directly; al/updateTests just keeps the cache current between explicit calls.
-- No uri_to_path calls happen here, so the notification never blocks the UI.

local function setup_notification_handlers()
    local prev_update = vim.lsp.handlers["al/updateTests"]
    vim.lsp.handlers["al/updateTests"] = function(err, result, ctx, config)
        if result and result.testItems then
            local client_id = ctx.client_id
            local items     = result.testItems
            vim.schedule(function()
                raw_tree[client_id] = items
                cache[client_id]    = nil  -- invalidate lazy per-file cache
                build_test_file_set(client_id)
            end)
        end
        if prev_update then prev_update(err, result, ctx, config) end
    end

    -- al/projectsLoadedNotification: invalidate cache, then immediately fire
    -- al/discoverTests — this is the reactive call VSCode makes on every notification.
    -- The response is a plain array (not wrapped in testItems like al/updateTests).
    -- Only store it if non-empty; an empty response means the server isn't ready yet
    -- and al/updateTests will arrive on its own.
    local prev_loaded = vim.lsp.handlers["al/projectsLoadedNotification"]
    vim.lsp.handlers["al/projectsLoadedNotification"] = function(err, result, ctx, config)
        local client_id = ctx.client_id
        M.invalidate(client_id)
        local client = vim.lsp.get_client_by_id(client_id)
        if client then
            client:request("al/discoverTests", {}, function(req_err, response)
                if not req_err and type(response) == "table" and #response > 0 then
                    vim.schedule(function()
                        raw_tree[client_id] = response
                        cache[client_id]    = nil
                        build_test_file_set(client_id)
                    end)
                end
            end)
        end
        if prev_loaded then prev_loaded(err, result, ctx, config) end
    end

    -- Apply patch + eager al/discoverTests fetch when an al_ls client attaches.
    -- This populates raw_tree and test_file_set before neotest's first is_test_file
    -- scan, breaking the bootstrapping chicken-and-egg problem.
    vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("neotest_al_lsp_patch", { clear = true }),
        callback = function(args)
            local c = vim.lsp.get_client_by_id(args.data.client_id)
            if c and c.name == "al_ls" then
                patch_rpc_class(c)
                c:request("al/discoverTests", {}, function(err, response)
                    if not err and type(response) == "table" and #response > 0 then
                        vim.schedule(function()
                            raw_tree[c.id] = response
                            cache[c.id]    = nil
                            build_test_file_set(c.id)
                        end)
                    end
                end)
            end
        end,
    })
end

-- Register immediately so we capture al/updateTests before discover_positions
-- is ever called.
setup_notification_handlers()

-- ── Fetch from LSP ────────────────────────────────────────────────────────────

---@param client vim.lsp.Client
local function fetch_and_cache(client)
    patch_rpc_class(client)

    while fetch_in_progress[client.id] do
        nio.sleep(20)
    end
    if raw_tree[client.id] then return end

    fetch_in_progress[client.id] = true

    -- al/discoverTests is the primary data source for discovery.
    -- Retry up to 10 s (50 × 200 ms) in case the server isn't ready yet and
    -- returns an empty response.  al/updateTests may also populate raw_tree
    -- reactively while we wait — bail early if it does.
    local request = nio.wrap(function(cb)
        client:request("al/discoverTests", {}, cb)
    end, 1)
    for _ = 1, 50 do
        if raw_tree[client.id] then break end  -- al/updateTests beat us to it
        local err, result = request()
        if not err and type(result) == "table" and #result > 0 then
            raw_tree[client.id] = result
            cache[client.id]    = nil
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
    if not client then return nil end

    if not raw_tree[client.id] then
        fetch_and_cache(client)
    end

    if not raw_tree[client.id] then return nil end

    local file_data = find_for_path(client.id, norm(path))
    if not file_data or #file_data.tests == 0 then
        return nil
    end

    -- Use the last test's end line for the file range.
    -- Avoids a blocking vim.fn.readfile call (which can stall the UI on Windows
    -- when the file is temporarily locked by AV or the AL Language Server).
    local last_test_range = file_data.tests[#file_data.tests].location.range
    local file_end_line   = last_test_range["end"].line

    local pos_list = {
        {
            type  = "file",
            path  = path,
            name  = file_data.codeunit_name,
            id    = path,
            range = { 0, 0, file_end_line, 0 },
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

--- Returns true if path is known to contain AL tests according to the LSP.
--- Returns false when the LSP hasn't loaded yet (neotest will retry on next scan).
--- No file I/O — O(1) lookup against the pre-built test_file_set.
---@param path string
---@return boolean
function M.is_test_file(path)
    local np = norm(path)
    for _, file_set in pairs(test_file_set) do
        if file_set[np] then return true end
    end
    return false
end

-- ── Test-only exports ─────────────────────────────────────────────────────────
M._find_client   = find_client
M._index_by_file = index_by_file
M._norm          = norm
M._test_file_set = test_file_set

--- Returns the test entry for a file path, extracting lazily from the raw tree.
--- Used by the LSP runner to get raw LSP test items for al/runTests.
---@param path string  normalized filesystem path
---@return { codeunit_name: string, codeunit_id: integer, tests: table[] }|nil
function M.get_items(path)
    local np = norm(path)
    for client_id in pairs(raw_tree) do
        local data = find_for_path(client_id, np)
        if data then return data end
    end
end

--- Returns the al_ls client responsible for the given path, or nil.
---@param path string
---@return vim.lsp.Client|nil
function M.get_client(path)
    return find_client(path)
end

return M
