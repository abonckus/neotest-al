describe("neotest-al.runner.lsp.diagnostics", function()
    local diag

    before_each(function()
        package.loaded["neotest-al.runner.lsp.diagnostics"] = nil
        diag = require("neotest-al.runner.lsp.diagnostics")
    end)

    -- ── parse_line ────────────────────────────────────────────────────────────
    describe("parse_line", function()
        it("returns nil for a plain log line", function()
            assert.is_nil(diag.parse_line("[2026-04-02] Preparing to build and publish projects..."))
        end)

        it("returns nil for an empty string", function()
            assert.is_nil(diag.parse_line(""))
        end)

        it("parses an error line correctly", function()
            local item = diag.parse_line(
                "c:/repos/myapp/src/Foo.al(12,4): error AL0001: Symbol 'Foo' is not found"
            )
            assert.is_not_nil(item)
            assert.are.equal(vim.fs.normalize("c:/repos/myapp/src/Foo.al"), item.file)
            assert.are.equal(12, item.line)
            assert.are.equal(4, item.col)
            assert.are.equal("error", item.severity)
            assert.are.equal("AL0001", item.code)
            assert.are.equal("Symbol 'Foo' is not found", item.message)
        end)

        it("parses a warning line correctly", function()
            local item = diag.parse_line(
                "c:/repos/myapp/src/Bar.al(5,10): warning AL0002: Unused variable 'x'"
            )
            assert.is_not_nil(item)
            assert.are.equal("warning", item.severity)
            assert.are.equal(5, item.line)
            assert.are.equal(10, item.col)
        end)

        it("returns nil for info severity lines", function()
            assert.is_nil(diag.parse_line(
                "c:/repos/myapp/src/Bar.al(1,1): info AL9999: Some informational note"
            ))
        end)

        it("handles Windows-style backslash paths", function()
            local item = diag.parse_line(
                "c:\\repos\\myapp\\src\\Foo.al(3,1): error AL0001: Test"
            )
            -- Should still parse (path normalised by caller)
            assert.is_not_nil(item)
            assert.are.equal(3, item.line)
        end)
    end)

    -- ── set and clear ─────────────────────────────────────────────────────────
    describe("set and clear", function()
        it("set does not error when given an empty list", function()
            assert.has_no.errors(function() diag.set({}) end)
        end)

        it("clear does not error", function()
            assert.has_no.errors(function() diag.clear() end)
        end)

        it("set does not error with valid error items", function()
            assert.has_no.errors(function()
                diag.set({
                    {
                        file     = vim.fn.tempname() .. ".al",
                        line     = 5,
                        col      = 1,
                        severity = "error",
                        code     = "AL0001",
                        message  = "Test error",
                    },
                })
            end)
        end)
    end)
end)
