local nio = require("nio")
local launch = require("neotest-al.runner.lsp.launch")
local dirty = require("neotest-al.runner.lsp.dirty")
local run = require("neotest-al.runner.lsp.run")
local diagnostics = require("neotest-al.runner.lsp.diagnostics")

local M = {}
M.name = "lsp"

local IS_WINDOWS = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1

--- Find the al_ls client whose root_dir is a prefix of path.
---@param path string
---@return vim.lsp.Client|nil
local function find_al_client(path)
    local np = vim.fs.normalize(path)
    if IS_WINDOWS then np = np:lower() end
    for _, client in ipairs(vim.lsp.get_clients({ name = "al_ls" })) do
        local root = vim.fs.normalize(client.root_dir or "")
        if IS_WINDOWS then root = root:lower() end
        if vim.startswith(np, root .. "/") or np == root then
            return client
        end
    end
end

-- Recursively walk a neotest Tree and collect raw LSP test items + position id_map.
-- Returns items[], id_map where id_map["codeunit_id:test_name"] = position_id.
-- Per-file caching avoids calling discovery.get_items multiple times for the
-- same file when a tree contains many tests from the same codeunit.
---@param tree neotest.Tree
---@param discovery neotest-al.Discovery
---@return table[], table<string, string>
local function collect_items(tree, discovery)
    local items      = {}
    local id_map     = {}
    local file_cache = {} -- path -> file_data|false

    local function traverse(node)
        local data = node:data()
        if data.type == "test" then
            local cached = file_cache[data.path]
            if cached == nil then
                local result = discovery.get_items(data.path)
                cached = result or false
                file_cache[data.path] = cached
            end
            local file_data = cached ~= false and cached or nil
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

-- Poll al/hasProjectClosureLoadedRequest until the project closure is loaded or timeout.
-- Matches VSCode's behaviour of polling this before sending al/runTests.
-- workspacePath is sent in OS-native backslash format on Windows.
---@async
---@param client       vim.lsp.Client
---@param workspace_root string  normalized (forward-slash) workspace root
---@param max_polls?   integer  max 200ms poll iterations (default 150 = 30 s); override in tests
---@return boolean
local function wait_for_project_closure(client, workspace_root, max_polls)
    max_polls = max_polls or 150
    local path = workspace_root
    if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
        path = workspace_root:gsub("/", "\\")
    end

    local request = nio.wrap(function(cb)
        client:request("al/hasProjectClosureLoadedRequest", { workspacePath = path }, cb)
    end, 1)

    for _ = 1, max_polls do
        local err, result = request()
        if not err and result and result.loaded then
            return true
        end
        nio.sleep(200)
    end
    return false
end

--- Create a new LSP runner instance.
---@param opts? { launch_json_path?: string, vscode_extension_version?: string, max_ticks?: integer, auth_timeout_ticks?: integer }
---@return neotest-al.Runner
function M.new(opts)
    opts = opts or {}
    local runner = { name = "lsp" }

    ---@async
    function runner.build_spec(args, discovery)
        local position = args.tree:data()

        -- Find the al_ls client for this workspace
        local client = find_al_client(position.path)
        if not client then
            vim.notify(
                "neotest-al: no AL LSP client found for " .. tostring(position.path),
                vim.log.levels.ERROR
            )
            return nil
        end

        local workspace_root = vim.fs.normalize(client.root_dir or "")

        -- Ensure project closure is loaded (VSCode always polls this before al/runTests)
        if not wait_for_project_closure(client, workspace_root, opts._closure_max_polls) then
            vim.notify(
                "neotest-al: AL project closure not loaded — ensure the AL extension has finished loading",
                vim.log.levels.WARN
            )
            return nil
        end

        -- Collect raw LSP test items + build the id_map
        local test_items, id_map = collect_items(args.tree, discovery)
        if #test_items == 0 then
            vim.notify("neotest-al: no test items found to run")
            return nil
        end

        -- Get launch configuration (may prompt with vim.ui.select)
        local config =
            launch.get_config(position.path, { launch_json_path = opts.launch_json_path })
        if not config then
            return nil
        end

        -- Determine SkipPublish from dirty state
        local skip_publish = not dirty.is_dirty(workspace_root)

        -- Execute tests (blocks until al/testRunComplete or timeout)
        local results_path = vim.fn.tempname() .. ".json"
        local success = run.execute(
            client,
            config,
            test_items,
            results_path,
            skip_publish,
            opts.vscode_extension_version,
            {
                max_ticks = opts.max_ticks,
                auth_timeout_ticks = opts.auth_timeout_ticks,
            }
        )

        -- Update dirty state
        if success and not skip_publish then
            dirty.mark_clean(workspace_root)
        end

        return {
            command = { vim.v.progpath, "--version" },
            context = {
                results_path = results_path,
                id_map = id_map,
            },
        }
    end

    ---@param spec neotest.RunSpec
    ---@param result neotest.StrategyResult
    ---@param tree neotest.Tree
    ---@return table<string, neotest.Result>
    function runner.results(spec, _result, tree)
        local f = io.open(spec.context.results_path, "r")
        if not f then
            return {}
        end
        local content = f:read("*a")
        f:close()

        local ok, data = pcall(vim.json.decode, content)
        if not ok or not data then
            return {}
        end

        -- Set vim diagnostics from build errors
        if data.build_errors and #data.build_errors > 0 then
            diagnostics.set(data.build_errors)
        end

        local output_path = vim.fn.tempname()
        local outf = io.open(output_path, "w")
        if outf then
            -- ANSI colour helpers
            local C = {
                reset = "\27[0m",
                bold = "\27[1m",
                dim = "\27[2m",
                red = "\27[31m",
                green = "\27[32m",
                yellow = "\27[33m",
                cyan = "\27[36m",
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
                    [0] = C.green .. "✓" .. C.reset,
                    [1] = C.red .. "✗" .. C.reset,
                    [2] = C.yellow .. "⊘" .. C.reset,
                }
                outf:write("\n\n" .. C.bold .. "Test Results:" .. C.reset .. "\n")
                for _, t in ipairs(data.tests) do
                    local icon = STATUS_FMT[t.status] or "?"
                    local name = t.status == 1 and (C.red .. t.name .. C.reset) or t.name
                    local duration = t.duration
                            and (C.dim .. " (" .. t.duration .. "ms)" .. C.reset)
                        or ""
                    outf:write(("  %s %s%s\n"):format(icon, name, duration))
                    if t.message and t.message ~= "" then
                        outf:write(("    " .. C.red .. t.message .. C.reset .. "\n"))
                    end
                end
            end

            outf:close()
        end
        local id_map = spec.context.id_map or {}
        local neotest_results = {}

        -- Helper: mark every node in the tree with the same result
        local function mark_all(node, res)
            neotest_results[node:data().id] = res
            for _, child in ipairs(node:children() or {}) do
                mark_all(child, res)
            end
        end

        -- Authentication failure: no tests ran, no compiler errors
        if data.auth_error and #(data.tests or {}) == 0 then
            mark_all(tree, {
                status = "skipped",
                short = "Authentication failed — run :AL authenticate",
                output = output_path,
            })
            return neotest_results
        end

        -- Build failure: no tests ran
        if #(data.build_errors or {}) > 0 and #(data.tests or {}) == 0 then
            mark_all(tree, {
                status = "skipped",
                short = "Build failed — see diagnostics",
                output = output_path,
            })
            return neotest_results
        end

        -- Map individual test results
        local STATUS = { [0] = "passed", [1] = "failed", [2] = "skipped" }
        for _, t in ipairs(data.tests or {}) do
            local key = tostring(t.codeunit_id) .. ":" .. t.name
            local pos_id = id_map[key]
            if pos_id then
                neotest_results[pos_id] = {
                    status = STATUS[t.status] or "failed",
                    short = t.message or "",
                    output = output_path,
                    duration = t.duration,
                }
            end
        end

        return neotest_results
    end

    return runner
end

return M
