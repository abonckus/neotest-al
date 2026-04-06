local nio = require("nio")
local diagnostics = require("neotest-al.runner.lsp.diagnostics")

local M = {}

-- Active run state, keyed by client_id.
-- Each run holds the accumulated data until al/testRunComplete fires.
-- { done, build_log, build_errors, tests, auth_error }
local active_runs = {}

-- Auth error patterns (case-insensitive match)
local AUTH_PATTERNS = { "unauthorized", "401", "authentication failed" }

local function is_auth_error(line)
    local lower = line:lower()
    for _, pat in ipairs(AUTH_PATTERNS) do
        if lower:find(pat, 1, true) then
            return true
        end
    end
    return false
end

-- Wire global LSP notification handlers once at module load.
-- Each handler filters by client_id so only active runs are touched.
local function setup_handlers()
    local prev_msg = vim.lsp.handlers["al/testExecutionMessage"]
    local prev_start = vim.lsp.handlers["al/testMethodStart"]
    local prev_finish = vim.lsp.handlers["al/testMethodFinish"]
    local prev_done = vim.lsp.handlers["al/testRunComplete"]

    vim.lsp.handlers["al/testExecutionMessage"] = function(err, result, ctx, config)
        local state = active_runs[ctx.client_id]
        if state and type(result) == "string" then
            table.insert(state.build_log, result)
            if is_auth_error(result) then
                state.auth_error = true
            end
            -- The server sometimes sends a multi-line blob in a single notification
            -- (e.g. a full publish-failure response). Split by line so parse_line
            -- can match individual compiler diagnostics embedded in the message.
            for line in result:gmatch("[^\r\n]+") do
                local err_item = diagnostics.parse_line(line)
                if err_item then
                    table.insert(state.build_errors, err_item)
                end
            end
        end
        if prev_msg then
            prev_msg(err, result, ctx, config)
        end
    end

    vim.lsp.handlers["al/testMethodStart"] = function(err, result, ctx, config)
        if prev_start then
            prev_start(err, result, ctx, config)
        end
    end

    vim.lsp.handlers["al/testMethodFinish"] = function(err, result, ctx, config)
        local state = active_runs[ctx.client_id]
        if state and result and type(result.name) == "string" and result.name ~= "" then
            table.insert(state.tests, {
                name = result.name,
                codeunit_id = result.codeunitId,
                status = result.status,
                message = result.message or "",
                duration = result.duration or 0,
            })
        end
        if prev_finish then
            prev_finish(err, result, ctx, config)
        end
    end

    vim.lsp.handlers["al/testRunComplete"] = function(err, result, ctx, config)
        local state = active_runs[ctx.client_id]
        if state then
            state.done = true
        end
        if prev_done then
            prev_done(err, result, ctx, config)
        end
    end
end

setup_handlers()

-- Maximum ticks to wait for al/testRunComplete before timing out (5 minutes).
local MAX_TICKS = 15000 -- 15000 × 20 ms = 300 s
-- Ticks at which we declare auth failure if got_401 and no messages arrived.
-- 250 × 20 ms = 5 s — long enough for publish-failure notifications to arrive,
-- short enough to give fast feedback when truly unauthenticated.
local AUTH_TIMEOUT_TICKS = 250

--- Send al/runTests and block until al/testRunComplete fires (or timeout).
--- Writes accumulated results to results_path as JSON.
---
---@async
---@param client       vim.lsp.Client
---@param config       table     launch.json configuration object
---@param test_items   table[]   raw LSP test item objects for al/runTests
---@param results_path string    path to write JSON results file
---@param skip_publish boolean   passed as SkipPublish to al/runTests
---@param opts?        { max_ticks?: integer, auth_timeout_ticks?: integer }
---@return boolean  true when run completed with no build errors
function M.execute(client, config, test_items, results_path, skip_publish, version, opts)
    diagnostics.clear()

    local state = {
        done = false,
        build_log = {},
        build_errors = {},
        tests = {},
        auth_error = false,
        got_401 = false, -- set when al/runTests response carries a 401 error
    }
    active_runs[client.id] = state

    opts = opts or {}
    local max_ticks = opts.max_ticks or MAX_TICKS
    local auth_timeout_ticks = opts.auth_timeout_ticks or AUTH_TIMEOUT_TICKS

    -- Fire al/runTests.
    -- The server returns a 401 error response both for genuine auth failures AND for
    -- some publish/compile failures.  We cannot declare auth failure from the response
    -- alone — instead we set got_401 and watch for al/testExecutionMessage activity.
    -- If no activity arrives within ~5 s the request was truly rejected, not just failed.
    client:request("al/runTests", {
        configuration = config,
        Tests = test_items,
        SkipPublish = skip_publish,
        VSCodeExtensionVersion = version or "18.0.0",
        CoverageMode = "none",
        Args = {},
    }, function(err)
        if err and type(err) == "table" and err.data == 401 then
            state.got_401 = true
        end
    end)

    -- Wait for al/testRunComplete (or bail early on genuine auth rejection).
    -- NOTE: auth-related strings in al/testExecutionMessage (e.g. from AL callstacks
    -- in test failures) set state.auth_error but must NOT abort the wait — the test
    -- may still complete normally.  Only bail early when the server returned 401 AND
    -- no execution messages have arrived (genuine rejection, no testRunComplete coming).
    local ticks = 0
    while not state.done and ticks < max_ticks do
        nio.sleep(20)
        ticks = ticks + 1
        -- If the server returned 401 but no al/testExecutionMessage has arrived
        -- within auth_timeout_ticks, this is a genuine auth rejection (the server
        -- won't send al/testRunComplete). Declare auth failure and exit.
        if state.got_401 and #state.build_log == 0 and ticks >= auth_timeout_ticks then
            state.auth_error = true
            break
        end
    end

    active_runs[client.id] = nil

    -- Only notify about auth failure when no tests ran at all.
    -- If tests did run, auth-related strings in the build log are likely
    -- false positives (e.g. BC internal logging or test code testing auth).
    if state.auth_error and #state.tests == 0 then
        vim.notify(
            "neotest-al: AL authentication failed — run :AL authenticate",
            vim.log.levels.ERROR
        )
    end

    -- Write results file
    local ok, encoded = pcall(vim.json.encode, {
        build_log = state.build_log,
        build_errors = state.build_errors,
        tests = state.tests,
        auth_error = state.auth_error,
    })
    if ok then
        local f = io.open(results_path, "w")
        if f then
            f:write(encoded)
            f:close()
        end
    end

    local success = #state.build_errors == 0
    return success
end

-- Test-only: reset active_runs to isolate tests.
function M._reset()
    active_runs = {}
end

return M
