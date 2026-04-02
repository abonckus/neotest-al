describe("neotest-al.runner.lsp.init", function()
    local lsp_runner

    -- Stub sub-modules so tests are isolated
    local stub_launch, stub_run

    before_each(function()
        package.loaded["neotest-al.runner.lsp.init"]        = nil
        package.loaded["neotest-al.runner.lsp.launch"]      = nil
        package.loaded["neotest-al.runner.lsp.run"]         = nil
        package.loaded["neotest-al.runner.lsp.diagnostics"] = nil

        -- Ensure nio is available (PlenaryBustedFile subprocess may not have nvim-nio in rtp)
        if not package.loaded["nio"] then
            local lazy = vim.fn.stdpath("data") .. "/lazy/nvim-nio"
            package.path = package.path .. ";" .. lazy .. "/lua/?.lua;" .. lazy .. "/lua/?/init.lua"
        end

        stub_launch = {
            get_config   = function() return { type = "al", name = "dev" } end,
            _find_workspace_root = function() return "/workspace" end,
            _read_json   = function() end,
            _config_cache = {},
        }
        stub_run = {
            execute = function(client, config, items, path)
                -- Write a minimal results file
                local f = io.open(path, "w")
                f:write(vim.json.encode({ build_log = {}, build_errors = {}, tests = {
                    { name = "TestA", codeunit_id = 500, status = 0, message = "", duration = 10 },
                } }))
                f:close()
                return true
            end,
            _reset = function() end,
        }

        package.loaded["neotest-al.runner.lsp.launch"]      = stub_launch
        package.loaded["neotest-al.runner.lsp.run"]         = stub_run
        package.loaded["neotest-al.runner.lsp.diagnostics"] = { set = function() end, clear = function() end, parse_line = function() end }

        lsp_runner = require("neotest-al.runner.lsp.init").new()
    end)

    local function run_async(fn)
        local nio = require("nio")
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

    local function make_tree(type, path, name, id, children)
        children = children or {}
        return {
            data     = function() return { type = type, path = path, name = name, id = id } end,
            children = function() return children end,
        }
    end

    local function make_discovery(items_by_path, client)
        return {
            get_items  = function(path) return items_by_path[vim.fs.normalize(path)] end,
            get_client = function(path) return client end,
            discover_positions = function() end,
            invalidate = function() end,
        }
    end

    -- ── build_spec ─────────────────────────────────────────────────────────────
    describe("build_spec", function()
        it("returns nil when discovery does not expose get_items", function()
            local discovery = { discover_positions = function() end, invalidate = function() end }
            local runner = require("neotest-al.runner.lsp.init").new()
            local spec = run_async(function()
                return runner.build_spec({ tree = make_tree("test", "/ws/F.al", "TestA", "/ws/F.al::TestA") }, discovery)
            end)
            assert.is_nil(spec)
        end)

        it("returns nil when no client found", function()
            local discovery = make_discovery({}, nil)
            local spec = run_async(function()
                return lsp_runner.build_spec(
                    { tree = make_tree("test", "/ws/F.al", "TestA", "/ws/F.al::TestA") },
                    discovery
                )
            end)
            assert.is_nil(spec)
        end)

        it("returns nil when no test items collected", function()
            local client    = { id = 600, root_dir = "/ws" }
            local discovery = make_discovery({}, client)  -- empty — get_items returns nil
            local spec = run_async(function()
                return lsp_runner.build_spec(
                    { tree = make_tree("test", "/ws/F.al", "TestA", "/ws/F.al::TestA") },
                    discovery
                )
            end)
            assert.is_nil(spec)
        end)

        it("returns spec with results_path and id_map", function()
            local client = { id = 601, root_dir = "/ws" }
            local norm   = vim.fs.normalize("/ws/F.al")
            local discovery = make_discovery({
                [norm] = {
                    codeunit_name = "My Codeunit",
                    codeunit_id   = 500,
                    tests = {
                        { name = "TestA", appId = "abc", codeunitId = 500, scope = 2,
                          location = { source = "file:///ws/F.al", range = { start = { line = 1, character = 0 }, ["end"] = { line = 1, character = 5 } } } },
                    },
                },
            }, client)

            local tree = make_tree("test", "/ws/F.al", "TestA", norm .. "::TestA")
            local spec = run_async(function()
                return lsp_runner.build_spec({ tree = tree }, discovery)
            end)

            assert.is_not_nil(spec)
            assert.is_not_nil(spec.context.results_path)
            assert.is_not_nil(spec.context.id_map)
            assert.are.equal(norm .. "::TestA", spec.context.id_map["500:TestA"])
        end)
    end)

    -- ── results ────────────────────────────────────────────────────────────────
    describe("results", function()
        local function write_results(path, data)
            local f = io.open(path, "w")
            f:write(vim.json.encode(data))
            f:close()
        end

        it("maps passed test to neotest passed status", function()
            local path = vim.fn.tempname() .. ".json"
            write_results(path, {
                build_log    = {},
                build_errors = {},
                tests        = { { name = "TestA", codeunit_id = 500, status = 0, message = "", duration = 42 } },
            })

            local spec = { context = { results_path = path, id_map = { ["500:TestA"] = "/ws/F.al::TestA" } } }
            local out  = lsp_runner.results(spec, {}, make_tree("file", "/ws/F.al", "My Codeunit", "/ws/F.al"))

            os.remove(path)
            assert.are.equal("passed", out["/ws/F.al::TestA"].status)
            assert.are.equal(42,       out["/ws/F.al::TestA"].duration)
        end)

        it("maps failed test to neotest failed status with message", function()
            local path = vim.fn.tempname() .. ".json"
            write_results(path, {
                build_log    = {},
                build_errors = {},
                tests        = { { name = "TestA", codeunit_id = 500, status = 1, message = "Assert failed", duration = 5 } },
            })

            local spec = { context = { results_path = path, id_map = { ["500:TestA"] = "/ws/F.al::TestA" } } }
            local out  = lsp_runner.results(spec, {}, make_tree("file", "/ws/F.al", "My Codeunit", "/ws/F.al"))

            os.remove(path)
            assert.are.equal("failed",       out["/ws/F.al::TestA"].status)
            assert.are.equal("Assert failed", out["/ws/F.al::TestA"].short)
        end)

        it("maps skipped test to neotest skipped status", function()
            local path = vim.fn.tempname() .. ".json"
            write_results(path, {
                build_log    = {},
                build_errors = {},
                tests        = { { name = "TestA", codeunit_id = 500, status = 2, message = "", duration = 0 } },
            })

            local spec = { context = { results_path = path, id_map = { ["500:TestA"] = "/ws/F.al::TestA" } } }
            local out  = lsp_runner.results(spec, {}, make_tree("file", "/ws/F.al", "My Codeunit", "/ws/F.al"))

            os.remove(path)
            assert.are.equal("skipped", out["/ws/F.al::TestA"].status)
        end)

        it("marks all tree nodes failed on build error with no tests", function()
            local path = vim.fn.tempname() .. ".json"
            write_results(path, {
                build_log    = { "output" },
                build_errors = { { file = "/ws/F.al", line = 1, col = 1, severity = "error", code = "AL0001", message = "oops" } },
                tests        = {},
            })

            local test_node = make_tree("test", "/ws/F.al", "TestA", "/ws/F.al::TestA")
            local file_node = make_tree("file", "/ws/F.al", "My Codeunit", "/ws/F.al", { test_node })
            local spec = { context = { results_path = path, id_map = {} } }
            local out  = lsp_runner.results(spec, {}, file_node)

            os.remove(path)
            assert.are.equal("skipped", out["/ws/F.al"].status)
            assert.are.equal("skipped", out["/ws/F.al::TestA"].status)
            assert.is_not_nil(out["/ws/F.al"].short:match("Build failed"))
        end)

        it("marks all tree nodes skipped on auth error with no tests", function()
            local path = vim.fn.tempname() .. ".json"
            write_results(path, {
                build_log    = { "Unauthorized\n" },
                build_errors = {},
                tests        = {},
                auth_error   = true,
            })

            local test_node = make_tree("test", "/ws/F.al", "TestA", "/ws/F.al::TestA")
            local file_node = make_tree("file", "/ws/F.al", "My Codeunit", "/ws/F.al", { test_node })
            local spec = { context = { results_path = path, id_map = {} } }
            local out  = lsp_runner.results(spec, {}, file_node)

            os.remove(path)
            assert.are.equal("skipped", out["/ws/F.al"].status)
            assert.are.equal("skipped", out["/ws/F.al::TestA"].status)
            assert.is_not_nil(out["/ws/F.al"].short:match("Authentication failed"))
        end)

        it("returns empty table when results file is missing", function()
            local spec = { context = { results_path = "/nonexistent.json", id_map = {} } }
            local out  = lsp_runner.results(spec, {}, make_tree("file", "/ws/F.al", "x", "/ws/F.al"))
            assert.are.same({}, out)
        end)
    end)
end)
