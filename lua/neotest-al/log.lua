-- Debug logging utility for neotest-al.
-- Writes timestamped lines to a log file so freeze issues can be diagnosed.
-- Log path: {vim stdpath cache}/neotest-al-debug.log
--
-- Usage: local log = require("neotest-al.log")
--        log.log("mymodule: entering my_function arg=" .. tostring(arg))
--
-- To watch in real time: tail -f ~/.local/state/nvim/neotest-al-debug.log
-- (or equivalent for your OS)

local M = {}

local _f = nil

local function get_file()
    if _f then
        return _f
    end
    local ok, dir = pcall(function()
        return vim.fn.stdpath("cache")
    end)
    local log_path = (ok and dir or "/tmp") .. "/neotest-al-debug.log"
    _f = io.open(log_path, "a")
    if _f then
        _f:write(
            "\n" .. os.date("[%Y-%m-%d %H:%M:%S]") .. " ===== neotest-al session start =====\n"
        )
        _f:flush()
    end
    return _f
end

--- Write a log line. Always flushes so partial logs are visible on freeze.
---@param msg string
function M.log(msg)
    local f = get_file()
    if f then
        f:write(os.date("[%H:%M:%S] ") .. tostring(msg) .. "\n")
        f:flush()
    end
end

return M
