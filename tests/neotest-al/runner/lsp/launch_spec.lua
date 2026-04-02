describe("neotest-al.runner.lsp.launch", function()
    local launch

    before_each(function()
        package.loaded["neotest-al.runner.lsp.launch"] = nil
        launch = require("neotest-al.runner.lsp.launch")
    end)

    -- ── _find_workspace_root ──────────────────────────────────────────────────
    describe("_find_workspace_root", function()
        it("returns nil when no app.json found walking up", function()
            -- /tmp has no app.json above it
            assert.is_nil(launch._find_workspace_root("/tmp/no-project/File.al"))
        end)

        it("finds app.json in parent directory", function()
            local orig = vim.fs.find
            vim.fs.find = function(name, opts)
                if name == "app.json" then
                    return { "/workspace/app.json" }
                end
                return orig(name, opts)
            end

            local root = launch._find_workspace_root("/workspace/src/File.al")
            vim.fs.find = orig
            assert.are.equal(vim.fs.normalize("/workspace"), root)
        end)
    end)

    -- ── _read_json ────────────────────────────────────────────────────────────
    describe("_read_json", function()
        it("returns nil for a file that does not exist", function()
            assert.is_nil(launch._read_json("/nonexistent/path/launch.json"))
        end)

        it("decodes valid JSON from a file", function()
            local path = vim.fn.tempname() .. ".json"
            local f = io.open(path, "w")
            f:write('{"configurations":[{"type":"al","request":"launch","name":"dev"}]}')
            f:close()

            local data = launch._read_json(path)
            assert.is_not_nil(data)
            assert.are.equal("al", data.configurations[1].type)

            os.remove(path)
        end)
    end)

    -- ── get_config ────────────────────────────────────────────────────────────
    describe("get_config", function()
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

        local function write_launch(path, configs)
            local f = io.open(path, "w")
            f:write(vim.json.encode({ configurations = configs }))
            f:close()
        end

        it("returns nil when launch.json does not exist", function()
            local orig_find = vim.fs.find
            vim.fs.find = function(name, opts)
                if name == "app.json" then return { "/workspace/app.json" } end
                return orig_find(name, opts)
            end

            local result = run_async(function()
                return launch.get_config("/workspace/src/File.al", {
                    launch_json_path = "/nonexistent/launch.json",
                })
            end)

            vim.fs.find = orig_find
            assert.is_nil(result)
        end)

        it("returns nil when no AL configs exist", function()
            local tmp = vim.fn.tempname() .. ".json"
            write_launch(tmp, { { type = "chrome", request = "launch", name = "web" } })

            local orig_find = vim.fs.find
            vim.fs.find = function(name, opts)
                if name == "app.json" then return { "/workspace/app.json" } end
                return orig_find(name, opts)
            end

            local result = run_async(function()
                return launch.get_config("/workspace/src/File.al", { launch_json_path = tmp })
            end)

            vim.fs.find = orig_find
            os.remove(tmp)
            assert.is_nil(result)
        end)

        it("returns the config directly when exactly one AL config exists", function()
            local tmp = vim.fn.tempname() .. ".json"
            write_launch(tmp, {
                { type = "al", request = "launch", name = "dev", server = "https://bc.example.com" },
            })

            local orig_find = vim.fs.find
            vim.fs.find = function(name, opts)
                if name == "app.json" then return { "/workspace/app.json" } end
                return orig_find(name, opts)
            end

            local result = run_async(function()
                return launch.get_config("/workspace/src/File.al", { launch_json_path = tmp })
            end)

            vim.fs.find = orig_find
            os.remove(tmp)
            assert.is_not_nil(result)
            assert.are.equal("dev", result.name)
            assert.are.equal("https://bc.example.com", result.server)
        end)

        it("calls vim.ui.select and returns chosen config when multiple AL configs exist", function()
            local tmp = vim.fn.tempname() .. ".json"
            write_launch(tmp, {
                { type = "al", request = "launch", name = "dev",  server = "https://dev.example.com" },
                { type = "al", request = "launch", name = "test", server = "https://test.example.com" },
            })

            local orig_find  = vim.fs.find
            local orig_select = vim.ui.select
            vim.fs.find = function(name, opts)
                if name == "app.json" then return { "/workspace/app.json" } end
                return orig_find(name, opts)
            end
            -- Simulate the user picking the second option
            vim.ui.select = function(items, opts, cb) cb(items[2], 2) end

            local result = run_async(function()
                return launch.get_config("/workspace/src/File.al", { launch_json_path = tmp })
            end)

            vim.fs.find  = orig_find
            vim.ui.select = orig_select
            os.remove(tmp)
            assert.is_not_nil(result)
            assert.are.equal("test", result.name)
        end)

        it("returns nil when user cancels vim.ui.select", function()
            local tmp = vim.fn.tempname() .. ".json"
            write_launch(tmp, {
                { type = "al", request = "launch", name = "dev" },
                { type = "al", request = "launch", name = "test" },
            })

            local orig_find  = vim.fs.find
            local orig_select = vim.ui.select
            vim.fs.find = function(name, opts)
                if name == "app.json" then return { "/workspace/app.json" } end
                return orig_find(name, opts)
            end
            vim.ui.select = function(items, opts, cb) cb(nil, nil) end

            local result = run_async(function()
                return launch.get_config("/workspace/src/File.al", { launch_json_path = tmp })
            end)

            vim.fs.find  = orig_find
            vim.ui.select = orig_select
            os.remove(tmp)
            assert.is_nil(result)
        end)

        it("returns nil when workspace root cannot be found", function()
            local orig_find = vim.fs.find
            vim.fs.find = function(name, opts)
                if name == "app.json" then return {} end  -- no app.json anywhere
                return orig_find(name, opts)
            end

            local notified = false
            local orig_notify = vim.notify
            vim.notify = function(msg, level)
                if msg:match("workspace root") then notified = true end
            end

            local result = run_async(function()
                return launch.get_config("/no-project/File.al", {})
            end)

            vim.fs.find = orig_find
            vim.notify = orig_notify
            assert.is_nil(result)
            assert.is_true(notified)
        end)

        it("returns cached config without re-reading launch.json on second call", function()
            local tmp = vim.fn.tempname() .. ".json"
            write_launch(tmp, {
                { type = "al", request = "launch", name = "cached", server = "https://cached.example.com" },
            })

            local orig_find = vim.fs.find
            local read_count = 0
            local orig_open = io.open
            local tmp_norm = vim.fs.normalize(tmp)
            io.open = function(path, mode)
                if vim.fs.normalize(path) == tmp_norm then read_count = read_count + 1 end
                return orig_open(path, mode)
            end
            vim.fs.find = function(name, opts)
                if name == "app.json" then return { "/workspace2/app.json" } end
                return orig_find(name, opts)
            end

            run_async(function()
                return launch.get_config("/workspace2/src/File.al", { launch_json_path = tmp })
            end)
            run_async(function()
                return launch.get_config("/workspace2/src/File.al", { launch_json_path = tmp })
            end)

            vim.fs.find = orig_find
            io.open = orig_open
            os.remove(tmp)
            assert.are.equal(1, read_count)
        end)

        it("resolves relative launch_json_path against workspace root", function()
            local root = vim.fn.tempname()
            vim.fn.mkdir(root, "p")
            local vscode_dir = root .. "/custom"
            vim.fn.mkdir(vscode_dir, "p")
            local launch_file = vscode_dir .. "/launch.json"
            write_launch(launch_file, {
                { type = "al", request = "launch", name = "relative", server = "https://rel.example.com" },
            })

            local orig_find = vim.fs.find
            vim.fs.find = function(name, opts)
                if name == "app.json" then return { root .. "/app.json" } end
                return orig_find(name, opts)
            end

            local result = run_async(function()
                return launch.get_config(root .. "/src/File.al", { launch_json_path = "custom/launch.json" })
            end)

            vim.fs.find = orig_find
            os.remove(launch_file)
            assert.is_not_nil(result)
            assert.are.equal("relative", result.name)
        end)
    end)
end)
