describe("neotest-al.runner.lsp.run", function()
    local run

    before_each(function()
        package.loaded["neotest-al.runner.lsp.run"] = nil
        -- diagnostics is a dep; stub it to avoid side effects
        package.loaded["neotest-al.runner.lsp.diagnostics"] = {
            parse_line = function(line)
                -- simple stub: detect "error" keyword
                if line:match("%((%d+),(%d+)%):%s*error") then
                    local file, ln, col = line:match("^(.-)%((%d+),(%d+)%)")
                    return { file = file, line = tonumber(ln), col = tonumber(col),
                             severity = "error", code = "AL0000", message = "stub" }
                end
            end,
            set   = function() end,
            clear = function() end,
        }
        run = require("neotest-al.runner.lsp.run")
    end)

    after_each(function()
        -- Clean up any leftover active run state
        run._reset()
    end)

    -- Helper: run async function
    local function run_async(fn)
        local nio    = require("nio")
        local result, err, done = nil, nil, false
        nio.run(function()
            local ok, val = pcall(fn)
            if ok then result = val else err = val end
            done = true
        end)
        vim.wait(5000, function() return done end, 10)
        if err then error(err, 2) end
        return result
    end

    -- Helper: simulate a client
    local function make_client(id)
        return {
            id = id,
            request = function(self, method, params, cb)
                -- Immediately acknowledge (no result, no error)
                vim.schedule(function() cb(nil, nil) end)
                return true, id
            end,
        }
    end

    -- Helper: fire a notification as if the LSP server sent it
    local function fire(method, result, client_id)
        local handler = vim.lsp.handlers[method]
        if handler then
            handler(nil, result, { client_id = client_id }, nil)
        end
    end

    it("accumulates test results from al/testMethodFinish", function()
        local client = make_client(300)
        local results_path = vim.fn.tempname() .. ".json"

        run_async(function()
            -- Start execute in a concurrent coroutine so we can fire events
            local nio = require("nio")
            local done = false
            nio.run(function()
                run.execute(client, {}, {}, results_path, false)
                done = true
            end)

            -- Let the request fire
            nio.sleep(50)

            -- Simulate test lifecycle
            fire("al/testMethodStart",  { name = "",       codeunitId = 400 }, 300)
            fire("al/testMethodStart",  { name = "TestA",  codeunitId = 400 }, 300)
            fire("al/testMethodFinish", { name = "TestA",  codeunitId = 400, status = 0, message = "", duration = 50 }, 300)
            fire("al/testMethodFinish", { name = "",       codeunitId = 400, status = 0, message = "", duration = 50 }, 300)
            fire("al/testRunComplete",  {}, 300)

            vim.wait(2000, function() return done end, 10)
        end)

        -- Read the results file
        local f = io.open(results_path, "r")
        assert.is_not_nil(f)
        local data = vim.json.decode(f:read("*a"))
        f:close()
        os.remove(results_path)

        assert.are.equal(1, #data.tests)
        assert.are.equal("TestA", data.tests[1].name)
        assert.are.equal(400, data.tests[1].codeunit_id)
        assert.are.equal(0, data.tests[1].status)
        assert.are.equal(50, data.tests[1].duration)
    end)

    it("skips empty-name testMethodFinish (codeunit-level finish)", function()
        local client = make_client(301)
        local results_path = vim.fn.tempname() .. ".json"

        run_async(function()
            local nio = require("nio")
            local done = false
            nio.run(function()
                run.execute(client, {}, {}, results_path, false)
                done = true
            end)
            nio.sleep(50)
            fire("al/testMethodFinish", { name = "", codeunitId = 401, status = 0, message = "", duration = 10 }, 301)
            fire("al/testRunComplete",  {}, 301)
            vim.wait(2000, function() return done end, 10)
        end)

        local f = io.open(results_path, "r")
        local data = vim.json.decode(f:read("*a"))
        f:close()
        os.remove(results_path)

        assert.are.equal(0, #data.tests)
    end)

    it("sets auth_error flag when build message contains Unauthorized", function()
        local client = make_client(302)
        local results_path = vim.fn.tempname() .. ".json"
        local notified = false
        local orig_notify = vim.notify
        vim.notify = function(msg, level)
            if msg:match("authentication failed") then notified = true end
        end

        run_async(function()
            local nio = require("nio")
            local done = false
            nio.run(function()
                run.execute(client, {}, {}, results_path, false)
                done = true
            end)
            nio.sleep(50)
            fire("al/testExecutionMessage", "Unauthorized access to server\r\n", 302)
            fire("al/testRunComplete", {}, 302)
            vim.wait(2000, function() return done end, 10)
        end)

        vim.notify = orig_notify
        os.remove(results_path)
        assert.is_true(notified)
    end)

    it("accumulates build log lines", function()
        local client = make_client(303)
        local results_path = vim.fn.tempname() .. ".json"

        run_async(function()
            local nio = require("nio")
            local done = false
            nio.run(function()
                run.execute(client, {}, {}, results_path, false)
                done = true
            end)
            nio.sleep(50)
            fire("al/testExecutionMessage", "[2026-04-02] Starting build\r\n", 303)
            fire("al/testExecutionMessage", "[2026-04-02] Build complete\r\n", 303)
            fire("al/testRunComplete", {}, 303)
            vim.wait(2000, function() return done end, 10)
        end)

        local f = io.open(results_path, "r")
        local data = vim.json.decode(f:read("*a"))
        f:close()
        os.remove(results_path)

        assert.are.equal(2, #data.build_log)
    end)

    it("returns true when no build errors occurred", function()
        local client = make_client(304)
        local results_path = vim.fn.tempname() .. ".json"
        local success

        run_async(function()
            local nio = require("nio")
            local done = false
            nio.run(function()
                success = run.execute(client, {}, {}, results_path, false)
                done = true
            end)
            nio.sleep(50)
            fire("al/testRunComplete", {}, 304)
            vim.wait(2000, function() return done end, 10)
        end)

        os.remove(results_path)
        assert.is_true(success)
    end)

    it("returns false when build errors are present", function()
        local client = make_client(305)
        local results_path = vim.fn.tempname() .. ".json"
        local success

        run_async(function()
            local nio = require("nio")
            local done = false
            nio.run(function()
                success = run.execute(client, {}, {}, results_path, false)
                done = true
            end)
            nio.sleep(50)
            fire("al/testExecutionMessage", "c:/src/Foo.al(1,1): error AL0001: Test", 305)
            fire("al/testRunComplete", {}, 305)
            vim.wait(2000, function() return done end, 10)
        end)

        os.remove(results_path)
        assert.is_false(success)
    end)
end)
