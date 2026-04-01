---@type neotest-al.Runner
local M = {}
M.name = "lsp"  -- display name

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
