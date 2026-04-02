-- Continia Test Runner
-- Implements the neotest-al.Runner interface using the altest.exe CLI.
-- This file is NOT part of the public neotest-al package — move to a
-- private repository and configure via:
--
--   require("neotest-al")({
--       runner = require("my-private-repo.continia-runner"),
--   })

local lib    = require("neotest.lib")
local logger = require("neotest.logging")
local async  = require("neotest.async")

---@type neotest-al.Runner
local M = {}
M.name = "continia"

-- ── Results parser ────────────────────────────────────────────────────────────

-- Parses XML produced by altest.exe:
--
-- <?xml version="1.0" encoding="UTF-8"?>
-- <alTestResults>
--   <testRun ...>
--     <rawResults>
--       <assemblies>
--         <assembly ...>
--           <collection ...>
--             <test name="Codeunit:Method" method="Method" time="0.82" result="Pass" />
--           </collection>
--         </assembly>
--       </assemblies>
--     </rawResults>
--   </testRun>
-- </alTestResults>
--
---@param spec neotest.RunSpec
---@param file_path string
---@return table<string, neotest.Result>
local function parse_xml_results(spec, file_path)
    local success, xml = pcall(lib.files.read, spec.context.results_path)
    if not success then
        logger.error("neotest-al continia runner: failed to read results from " .. spec.context.results_path)
        return {}
    end

    local results = {}
    for _test_name, method, time, result in
        xml:gmatch('<test name="(.-)" method="(.-)" time="(.-)" result="(.-)" />')
    do
        local status
        if result == "Pass" then
            status = "passed"
        elseif result == "Fail" then
            status = "failed"
        else
            status = "skipped"
        end

        results[file_path .. "::" .. method] = {
            status   = status,
            duration = tonumber(time) * 1000, -- convert seconds → milliseconds
        }
    end

    return results
end

-- ── Runner interface ──────────────────────────────────────────────────────────

---@param args neotest.RunArgs
---@param discovery neotest-al.Discovery
---@return neotest.RunSpec|nil
function M.build_spec(args, discovery)
    local results_path = async.fn.tempname()
    local position     = args.tree:data()

    local tbl_cmd = {
        "C:\\Users\\arbo\\Documents\\source\\repos\\al-test-runner-cli\\bin\\altest.exe",
        "test",
        "dev",
        "--api-key",
        "LngWgdn0OAafxfSYSYfUOQHrGbwScYWXMas9tmyclQOZcehnM3Z5UFHmE21GNQLW8J8GT6O4WNPWOQku2vjS_z3TfEcBfFr-WnNB40Uk1kpFBfOu-5Mnutx-asy4E-1YY_XabCubYQg0xMgyenLXEs5CSdSqYccXA3Xlc5rTXyQQeyon1Eiifwph83ZQjc2T6LcDeVvwgeVCI_Nlr2ViYEQPvQ3SfMJGIIrQQBv19lygYjYpgPTY4F2qhYGEKGoco0_7O7sdwiycJISTJaQhYHITk5oVwPY0FGnZf1EVM1_geWzm1O2FgCP4xwY5nUChj3_9ioqqkSVEgkw5qiDR5B3DMTkdEOv_IxAHtEnwCRw",
        "--output",
        results_path,
    }

    if position.type ~= "dir" then
        local content       = lib.files.read(position.path)
        local codeunit_name = content:match('[Cc]odeunit%s+%d+%s+[%"]?([%w%s_%.%-]+)[%"]?')
        if codeunit_name then
            table.insert(tbl_cmd, "--codeunit")
            table.insert(tbl_cmd, codeunit_name)
        else
            logger.error("neotest-al continia runner: could not find codeunit name in " .. position.path)
            return nil
        end
    end

    if position.type == "test" then
        table.insert(tbl_cmd, "--method")
        table.insert(tbl_cmd, position.name)
    end

    return {
        command = vim.tbl_flatten(tbl_cmd),
        context = {
            results_path = results_path,
            file         = position.path,
            id           = position.id,
        },
    }
end

---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result>
function M.results(spec, result, tree)
    return parse_xml_results(spec, spec.context.file)
end

return M
