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
-- Marks the owning workspace as dirty.
--
-- We deliberately avoid vim.fs.find (filesystem walk) in this callback —
-- even deferred via vim.schedule, it can stall the UI on Windows when
-- antivirus scanning is active.  Instead we match the saved file's path
-- against the set of workspace roots that init.lua has already populated
-- via mark_clean().  Before any test run all workspaces are considered
-- dirty by default (is_dirty returns true for never-published roots), so
-- missing a pre-run save is harmless.
vim.api.nvim_create_autocmd("BufWritePost", {
    group   = vim.api.nvim_create_augroup("neotest_al_dirty_tracker", { clear = true }),
    pattern = "*.al",
    callback = function(args)
        local file_path = args.match or args.file
        if not file_path then return end
        local norm = vim.fs.normalize(file_path)
        -- Find a known root that is a prefix of this file path.
        local matched = false
        for root in pairs(published) do
            if norm:sub(1, #root) == root then
                dirty[root] = true
                matched = true
            end
        end
        -- If no known root yet (no test run has completed), mark every
        -- known root dirty as a conservative fallback.
        if not matched then
            for root in pairs(dirty) do
                dirty[root] = true
            end
        end
    end,
})

return M
