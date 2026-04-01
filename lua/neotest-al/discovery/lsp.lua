local Tree = require("neotest.types").Tree
local nio  = require("nio")

---@type neotest-al.Discovery
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
    -- fetch + Tree building added in Task 5
    return nil
end

-- ── Test-only exports ─────────────────────────────────────────────────────────
M._find_client   = find_client
M._index_by_file = index_by_file

return M
