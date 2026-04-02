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
        -- Defer filesystem I/O so the save itself is not blocked.
        vim.schedule(function()
            local found = vim.fs.find("app.json", {
                path   = vim.fs.dirname(vim.fs.normalize(file_path)),
                upward = true,
                limit  = 1,
            })
            if found and #found > 0 then
                local root = vim.fs.normalize(vim.fs.dirname(found[1]))
                M.mark_dirty(root)
            end
        end)
    end,
})

return M
