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

-- Apply patch to al_ls clients that connect after this module loads.
vim.api.nvim_create_autocmd("LspAttach", {
    group = vim.api.nvim_create_augroup("neotest_al_lsp_patch", { clear = true }),
    callback = function(args)
        if _class_patched then return end
        local c = vim.lsp.get_client_by_id(args.data.client_id)
        if c and c.name == "al_ls" then
            patch_rpc_class(c)
        end
    end,
})

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
    -- Belt-and-suspenders: patch now in case the eager path above hasn't fired yet.
    patch_rpc_class(client)

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
