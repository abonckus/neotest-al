local lib = require("neotest.lib")

---@param config? { discovery?: neotest-al.Discovery, runner?: neotest-al.Runner }
---@return neotest.Adapter
return function(config)
    config = config or {}

    local discovery = config.discovery or require("neotest-al.discovery.lsp")
    local runner = config.runner or require("neotest-al.runner.lsp")

    assert(
        type(discovery.discover_positions) == "function",
        "neotest-al: discovery must implement discover_positions(path)"
    )
    assert(
        type(discovery.invalidate) == "function",
        "neotest-al: discovery must implement invalidate(client_id?)"
    )
    assert(
        type(discovery.is_test_file) == "function",
        "neotest-al: discovery must implement is_test_file(path)"
    )
    assert(
        type(discovery.get_items) == "function",
        "neotest-al: discovery must implement get_items(path)"
    )
    assert(
        type(runner.build_spec) == "function",
        "neotest-al: runner must implement build_spec(args, discovery)"
    )
    assert(
        type(runner.results) == "function",
        "neotest-al: runner must implement results(spec, result, tree)"
    )

    ---@type neotest.Adapter
    return {
        name = "neotest-al",
        root = lib.files.match_root_pattern(".alpackages", "app.json"),

        is_test_file = function(path)
            return discovery.is_test_file(path)
        end,

        ---@async
        discover_positions = function(path)
            return discovery.discover_positions(path)
        end,

        build_spec = function(args)
            return runner.build_spec(args, discovery)
        end,

        results = function(spec, result, tree)
            return runner.results(spec, result, tree)
        end,
    }
end
