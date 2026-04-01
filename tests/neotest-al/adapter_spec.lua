describe("neotest-al.adapter", function()
    local create_adapter

    before_each(function()
        package.loaded["neotest-al.adapter"] = nil
        create_adapter = require("neotest-al.adapter")
    end)

    local function stub_discovery(overrides)
        local t = {
            name               = "stub",
            discover_positions = function() end,
            invalidate         = function() end,
        }
        if overrides then
            for k, v in pairs(overrides) do t[k] = v end
            -- allow explicit nil removal via sentinel
            for k, _ in pairs({ discover_positions = true, invalidate = true, name = true }) do
                if overrides[k] == false then t[k] = nil end
            end
        end
        return t
    end

    local function stub_runner(overrides)
        local t = {
            name       = "stub",
            build_spec = function() end,
            results    = function() end,
        }
        if overrides then
            for k, v in pairs(overrides) do t[k] = v end
            for k, _ in pairs({ build_spec = true, results = true, name = true }) do
                if overrides[k] == false then t[k] = nil end
            end
        end
        return t
    end

    it("raises when discovery is missing discover_positions", function()
        assert.has_error(function()
            create_adapter({
                discovery = stub_discovery({ discover_positions = false }),
                runner    = stub_runner(),
            })
        end, "neotest-al: discovery must implement discover_positions(path)")
    end)

    it("raises when discovery is missing invalidate", function()
        assert.has_error(function()
            create_adapter({
                discovery = stub_discovery({ invalidate = false }),
                runner    = stub_runner(),
            })
        end, "neotest-al: discovery must implement invalidate(client_id?)")
    end)

    it("raises when runner is missing build_spec", function()
        assert.has_error(function()
            create_adapter({
                discovery = stub_discovery(),
                runner    = stub_runner({ build_spec = false }),
            })
        end, "neotest-al: runner must implement build_spec(args, discovery)")
    end)

    it("raises when runner is missing results", function()
        assert.has_error(function()
            create_adapter({
                discovery = stub_discovery(),
                runner    = stub_runner({ results = false }),
            })
        end, "neotest-al: runner must implement results(spec, result, tree)")
    end)

    it("returns a neotest adapter table with required fields", function()
        local adapter = create_adapter({
            discovery = stub_discovery(),
            runner    = stub_runner(),
        })
        assert.are.equal("neotest-al", adapter.name)
        assert.is_function(adapter.discover_positions)
        assert.is_function(adapter.build_spec)
        assert.is_function(adapter.results)
        assert.is_function(adapter.is_test_file)
        assert.is_not_nil(adapter.root)
    end)

    it("passes discovery as second arg to runner.build_spec", function()
        local received_discovery = nil
        local discovery = stub_discovery()
        local runner = stub_runner({
            build_spec = function(args, disc)
                received_discovery = disc
                return nil
            end,
        })

        local adapter = create_adapter({ discovery = discovery, runner = runner })
        adapter.build_spec({ tree = { data = function() return { type = "test", path = "" } end } })

        assert.are.equal(discovery, received_discovery)
    end)
end)
