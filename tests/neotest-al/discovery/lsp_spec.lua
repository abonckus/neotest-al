describe("neotest-al.discovery.lsp", function()
    local lsp

    before_each(function()
        package.loaded["neotest-al.discovery.lsp"] = nil
        lsp = require("neotest-al.discovery.lsp")
    end)

    -- ── _find_client ──────────────────────────────────────────────────────────
    describe("_find_client", function()
        it("returns nil when no al_ls clients exist", function()
            local orig = vim.lsp.get_clients
            vim.lsp.get_clients = function() return {} end

            assert.is_nil(lsp._find_client("/workspace/File.al"))

            vim.lsp.get_clients = orig
        end)

        it("returns client whose root_dir is a prefix of the path", function()
            local mock = { id = 1, root_dir = "/workspace", name = "al_ls" }
            local orig = vim.lsp.get_clients
            vim.lsp.get_clients = function() return { mock } end

            assert.are.equal(mock, lsp._find_client("/workspace/Src/File.al"))

            vim.lsp.get_clients = orig
        end)

        it("returns nil when path is outside all client root_dirs", function()
            local mock = { id = 1, root_dir = "/workspace", name = "al_ls" }
            local orig = vim.lsp.get_clients
            vim.lsp.get_clients = function() return { mock } end

            assert.is_nil(lsp._find_client("/other/File.al"))

            vim.lsp.get_clients = orig
        end)
    end)

    -- ── _index_by_file ────────────────────────────────────────────────────────
    describe("_index_by_file", function()
        local function make_response(file_uri)
            return {
                {
                    name = "Test App",
                    children = {
                        {
                            name       = "My Test Codeunit",
                            codeunitId = 50100,
                            children   = {
                                {
                                    name     = "Test_ShouldPass",
                                    location = {
                                        source = file_uri,
                                        range  = {
                                            start  = { line = 5, character = 14 },
                                            ["end"] = { line = 5, character = 28 },
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            }
        end

        it("groups tests under their normalized file path", function()
            local uri   = "file:///workspace/File.al"
            local fpath = vim.fs.normalize(vim.uri_to_fname(uri))
            local result = lsp._index_by_file(make_response(uri))

            assert.is_not_nil(result[fpath])
            assert.are.equal("My Test Codeunit", result[fpath].codeunit_name)
            assert.are.equal(50100, result[fpath].codeunit_id)
            assert.are.equal(1, #result[fpath].tests)
            assert.are.equal("Test_ShouldPass", result[fpath].tests[1].name)
        end)

        it("returns empty table for nil/empty input", function()
            assert.are.same({}, lsp._index_by_file(nil))
            assert.are.same({}, lsp._index_by_file({}))
        end)
    end)

    -- ── invalidate ────────────────────────────────────────────────────────────
    describe("invalidate", function()
        it("clears a specific client's cache without error", function()
            assert.has_no.errors(function() lsp.invalidate(42) end)
        end)

        it("clears all cache when called without arguments", function()
            assert.has_no.errors(function() lsp.invalidate() end)
        end)
    end)
end)
