local create_adapter = require("neotest-al.adapter")

local ALNeotestAdapter = create_adapter({})

setmetatable(ALNeotestAdapter, {
    __call = function(_, opts)
        opts = opts or {}
        return create_adapter(opts)
    end,
})

ALNeotestAdapter.setup = function(opts)
    return ALNeotestAdapter(opts)
end

return ALNeotestAdapter
