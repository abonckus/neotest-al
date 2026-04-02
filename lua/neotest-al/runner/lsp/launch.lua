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
