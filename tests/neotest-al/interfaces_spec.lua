describe("interfaces", function()
    it("discovery typedef module loads without error", function()
        assert.has_no.errors(function()
            require("neotest-al.discovery")
        end)
    end)

    it("runner typedef module loads without error", function()
        assert.has_no.errors(function()
            require("neotest-al.runner")
        end)
    end)

    it("lsp runner loads without error", function()
        assert.has_no.errors(function()
            require("neotest-al.runner.lsp")
        end)
    end)

    it("lsp runner build_spec returns nil and notifies", function()
        local notified = false
        local orig = vim.notify
        vim.notify = function(msg, level)
            if msg:match("LSP runner is not yet implemented") then
                notified = true
            end
        end

        local runner = require("neotest-al.runner.lsp")
        local result = runner.build_spec({}, {})
        vim.notify = orig

        assert.is_nil(result)
        assert.is_true(notified)
    end)

    it("lsp runner results returns empty table", function()
        local runner = require("neotest-al.runner.lsp")
        assert.are.same({}, runner.results({}, {}, {}))
    end)
end)
