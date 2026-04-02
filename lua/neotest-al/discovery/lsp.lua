local Tree = require("neotest.types").Tree
local nio  = require("nio")

---@type neotest-al.Discovery
local M = {}
M.name = "lsp"

-- cache[client_id] = { [norm_file_path] = { codeunit_name, codeunit_id, tests[] } }
local cache = {}

-- fetch_in_progress[client_id] = true while an al/discoverTests request is in flight.
-- Prevents N concurrent discover_positions calls from each sending a separate request.
local fetch_in_progress = {}

-- true once vim.lsp.rpc.Client.handle_body has been patched at the class level.
-- Patching the class fixes all instances (existing and future), so one patch is enough.
local _class_patched = false

-- ── Client patching ──────────────────────────────────────────────────────────
--
-- The AL Language Server sends JSON-RPC responses with `"error": null` alongside
-- a valid `result`. In Lua, `vim.NIL` (how null is decoded) is truthy but not a
-- table, so Neovim's assertion `assert(type(decoded.error) == 'table')` in
-- rpc.lua:452 fires, the response callback is never called, and our nio coroutine
-- hangs forever.
--
-- Fix: shadow `handle_body` on the vim.lsp.rpc.Client instance (the low-level
-- RPC client, NOT the vim.lsp.Client returned by vim.lsp.get_clients) to strip
-- `"error": null` before Neovim processes the body.
--
-- vim.lsp.Client.rpc is a PublicClient whose .request closure captures the
-- vim.lsp.rpc.Client as upvalue "client". We retrieve it with debug.getupvalue.

---@param lsp_client vim.lsp.Client
---@return table|nil  the vim.lsp.rpc.Client instance, or nil if not reachable
local function get_rpc_client(lsp_client)
    -- vim.lsp.Client.rpc is a public_client table whose .request closure captures
    -- the vim.lsp.rpc.Client instance as upvalue "client".
    local fn = lsp_client.rpc and lsp_client.rpc.request
    if type(fn) ~= "function" then return nil end
    for i = 1, 30 do
        local name, val = debug.getupvalue(fn, i)
        if not name then break end
        if name == "client" then return val end
    end
end

---Patch vim.lsp.rpc.Client.handle_body at the class level so that the
---AL server's `"error": null` responses don't trigger the assertion at
---rpc.lua:452. Patching the class fixes all instances (present and future).
---
---@param lsp_client vim.lsp.Client
local function ensure_client_patched(lsp_client)
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
        -- AL server sends {"error": null, "result": [...]}.
        -- vim.NIL (JSON null) is truthy but not a table, causing
        -- assert(type(decoded.error) == 'table') at rpc.lua:452 to fire,
        -- which prevents the response callback from ever being called.
        -- Normalize null → absent so Neovim handles the response normally.
        local ok, decoded = pcall(vim.json.decode, body, { luanil = { object = true } })
        if ok and type(decoded) == "table" and decoded.error == vim.NIL then
            decoded.error = nil
            body = vim.json.encode(decoded)
        end
        return orig(self, body)
    end
end

-- ── Client resolution ─────────────────────────────────────────────────────────

---@param path string
---@return vim.lsp.Client|nil
local function find_client(path)
    local norm = vim.fs.normalize(path)
    for _, client in ipairs(vim.lsp.get_clients({ name = "al_ls" })) do
        local root = vim.fs.normalize(client.root_dir or "")
        if #root > 0 and norm:sub(1, #root) == root and norm:sub(#root + 1, #root + 1) == "/" then
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
        cache             = {}
        fetch_in_progress = {}
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

-- ── Fetch from LSP ────────────────────────────────────────────────────────────

---@param client vim.lsp.Client
---@return table<string, any>
local function fetch_and_cache(client)
    -- Patch the client once so "error": null responses don't crash Neovim's RPC.
    ensure_client_patched(client)

    -- If another coroutine is already fetching for this client, wait for it to
    -- finish rather than sending a duplicate al/discoverTests request.
    while fetch_in_progress[client.id] do
        nio.sleep(20)
    end
    if cache[client.id] then
        return cache[client.id]
    end

    fetch_in_progress[client.id] = true
    local request = nio.wrap(function(cb)
        client:request("al/discoverTests", {}, cb)
    end, 1)
    local err, result = request()
    fetch_in_progress[client.id] = nil

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

    local lines = vim.fn.readfile(path)
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

-- ── Test-only exports ─────────────────────────────────────────────────────────
M._find_client   = find_client
M._index_by_file = index_by_file

return M
