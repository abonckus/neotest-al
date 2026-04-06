local M = {}

local NS = vim.api.nvim_create_namespace("neotest-al-build")

-- AL compiler error format:
--   /path/to/File.al(line,col): error|warning AL0000: message
-- Backslash paths (Windows) also work because Lua patterns treat \ literally.
-- Pattern captures: file, line, col, severity, code, message
-- Note: Lua patterns don't support alternation, so we match any word and validate in code
local PATTERN = "^(.-)%((%d+),(%d+)%):%s*(%a+)%s+(%S+):%s+(.+)$"

--- Parse a single al/testExecutionMessage line.
--- Returns a structured error item, or nil if the line is not a compiler diagnostic.
---@param line string
---@return { file: string, line: integer, col: integer, severity: string, code: string, message: string }|nil
function M.parse_line(line)
    local file, ln, col, severity, code, msg = line:match(PATTERN)
    if not file then
        return nil
    end
    -- Only accept error and warning; exclude info
    if severity ~= "error" and severity ~= "warning" then
        return nil
    end
    return {
        file = vim.fs.normalize(file),
        line = tonumber(ln),
        col = tonumber(col),
        severity = severity,
        code = code,
        message = msg,
    }
end

--- Set vim diagnostics for a list of parsed build errors.
--- Errors and warnings are shown; info lines are excluded by parse_line already.
---@param errors { file: string, line: integer, col: integer, severity: string, code: string, message: string }[]
function M.set(errors)
    if #errors == 0 then
        return
    end

    -- Group by file
    local by_file = {}
    for _, e in ipairs(errors) do
        if not by_file[e.file] then
            by_file[e.file] = {}
        end
        local sev = e.severity == "error" and vim.diagnostic.severity.ERROR
            or vim.diagnostic.severity.WARN
        table.insert(by_file[e.file], {
            lnum = e.line - 1, -- 0-based
            col = e.col - 1, -- 0-based
            severity = sev,
            message = ("[%s] %s"):format(e.code, e.message),
            source = "neotest-al",
        })
    end

    for file, diags in pairs(by_file) do
        local bufnr = vim.fn.bufadd(file)
        vim.diagnostic.set(NS, bufnr, diags)
    end
end

--- Clear all build diagnostics set by this module.
function M.clear()
    vim.diagnostic.reset(NS)
end

return M
