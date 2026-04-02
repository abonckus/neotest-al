local launch      = require("neotest-al.runner.lsp.launch")
local run         = require("neotest-al.runner.lsp.run")
local diagnostics = require("neotest-al.runner.lsp.diagnostics")

local M = {}
M.name = "lsp"

-- Recursively walk a neotest Tree and collect raw LSP test items + position id_map.
-- Returns items[], id_map where id_map["codeunit_id:test_name"] = position_id.
---@param tree neotest.Tree
---@param discovery neotest-al.Discovery
---@return table[], table<string, string>
local function collect_items(tree, discovery)
    local items  = {}
    local id_map = {}

    local function traverse(node)
        local data = node:data()
        if data.type == "test" then
            local file_data = discovery.get_items(data.path)
            if file_data then
                for _, raw in ipairs(file_data.tests or {}) do
                    if raw.name == data.name then
                        table.insert(items, raw)
                        local key = tostring(file_data.codeunit_id) .. ":" .. data.name
                        id_map[key] = data.id
                        break
                    end
                end
            end
        end
        for _, child in ipairs(node:children() or {}) do
            traverse(child)
        end
    end

    traverse(tree)
    return items, id_map
end

--- Create a new LSP runner instance.
---@param opts? { launch_json_path?: string, vscode_extension_version?: string }
---@return neotest-al.Runner
function M.new(opts)
    opts = opts or {}
    local runner = { name = "lsp" }

    ---@async
    function runner.build_spec(args, discovery)
        -- Require the LSP discovery's get_items / get_client extensions
        if type(discovery.get_items) ~= "function" or type(discovery.get_client) ~= "function" then
            vim.notify(
                "neotest-al: LSP runner requires LSP discovery (discovery.get_items not found)",
                vim.log.levels.ERROR
            )
            return nil
        end

        local position = args.tree:data()

        -- Find the client for this workspace
        local client = discovery.get_client(position.path)
        if not client then
            vim.notify(
                "neotest-al: no AL LSP client found for " .. tostring(position.path),
                vim.log.levels.ERROR
            )
            return nil
        end

        -- Collect raw LSP test items + build the id_map
        local test_items, id_map = collect_items(args.tree, discovery)
        if #test_items == 0 then
            vim.notify("neotest-al: no test items found to run", vim.log.levels.WARN)
            return nil
        end

        -- Get launch configuration (may prompt with vim.ui.select)
        local config = launch.get_config(position.path, { launch_json_path = opts.launch_json_path })
        if not config then return nil end

        -- Execute tests (blocks until al/testRunComplete or timeout)
        local results_path = vim.fn.tempname() .. ".json"
        run.execute(client, config, test_items, results_path, opts.vscode_extension_version)

        return {
            command = { vim.v.progpath, "--version" },
            context = {
                results_path = results_path,
                id_map       = id_map,
            },
        }
    end

    ---@param spec neotest.RunSpec
    ---@param result neotest.StrategyResult
    ---@param tree neotest.Tree
    ---@return table<string, neotest.Result>
    function runner.results(spec, result, tree)
        local f = io.open(spec.context.results_path, "r")
        if not f then return {} end
        local content = f:read("*a")
        f:close()

        local ok, data = pcall(vim.json.decode, content)
        if not ok or not data then return {} end

        -- Set vim diagnostics from build errors
        if data.build_errors and #data.build_errors > 0 then
            diagnostics.set(data.build_errors)
        end

        local output_path = vim.fn.tempname()
        local outf = io.open(output_path, "w")
        if outf then
            -- ANSI colour helpers
            local C = {
                reset   = "\27[0m",
                bold    = "\27[1m",
                dim     = "\27[2m",
                red     = "\27[31m",
                green   = "\27[32m",
                yellow  = "\27[33m",
                cyan    = "\27[36m",
            }

            -- Build log -------------------------------------------------------
            -- Normalise each message to a single line: strip \r, trim trailing
            -- newline, then re-join with \n.  al/testExecutionMessage chunks
            -- sometimes arrive without a trailing newline, so joining with ""
            -- causes lines to run together.
            -- Colour compiler diagnostics by severity.
            local lines = {}
            for _, msg in ipairs(data.build_log or {}) do
                local norm = msg:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n+$", "")
                if norm:find(": error ", 1, true) then
                    norm = C.red .. norm .. C.reset
                elseif norm:find(": warning ", 1, true) then
                    norm = C.yellow .. norm .. C.reset
                elseif norm:find(": info ", 1, true) then
                    norm = C.dim .. norm .. C.reset
                end
                table.insert(lines, norm)
            end
            outf:write(table.concat(lines, "\n"))

            -- Test results ----------------------------------------------------
            if data.tests and #data.tests > 0 then
                local STATUS_FMT = {
                    [0] = C.green  .. "✓" .. C.reset,
                    [1] = C.red    .. "✗" .. C.reset,
                    [2] = C.yellow .. "⊘" .. C.reset,
                }
                outf:write("\n\n" .. C.bold .. "Test Results:" .. C.reset .. "\n")
                for _, t in ipairs(data.tests) do
                    local icon     = STATUS_FMT[t.status] or "?"
                    local name     = t.status == 1 and (C.red .. t.name .. C.reset) or t.name
                    local duration = t.duration and (C.dim .. " (" .. t.duration .. "ms)" .. C.reset) or ""
                    outf:write(("  %s %s%s\n"):format(icon, name, duration))
                    if t.message and t.message ~= "" then
                        outf:write(("    " .. C.red .. t.message .. C.reset .. "\n"))
                    end
                end
            end

            outf:close()
        end
        local id_map  = spec.context.id_map or {}
        local neotest_results = {}

        -- Helper: mark every node in the tree with the same result
        local function mark_all(node, result)
            neotest_results[node:data().id] = result
            for _, child in ipairs(node:children() or {}) do
                mark_all(child, result)
            end
        end

        -- Authentication failure: no tests ran, no compiler errors
        if data.auth_error and #(data.tests or {}) == 0 then
            mark_all(tree, {
                status = "skipped",
                short  = "Authentication failed — run :AL authenticate",
                output = output_path,
            })
            return neotest_results
        end

        -- Build failure: no tests ran
        if #(data.build_errors or {}) > 0 and #(data.tests or {}) == 0 then
            mark_all(tree, {
                status = "skipped",
                short  = "Build failed — see diagnostics",
                output = output_path,
            })
            return neotest_results
        end

        -- Map individual test results
        local STATUS = { [0] = "passed", [1] = "failed", [2] = "skipped" }
        for _, t in ipairs(data.tests or {}) do
            local key    = tostring(t.codeunit_id) .. ":" .. t.name
            local pos_id = id_map[key]
            if pos_id then
                neotest_results[pos_id] = {
                    status   = STATUS[t.status] or "failed",
                    short    = t.message or "",
                    output   = output_path,
                    duration = t.duration,
                }
            end
        end

        return neotest_results
    end

    return runner
end

return M
