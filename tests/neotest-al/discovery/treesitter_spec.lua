local treesitter = require("neotest-al.discovery.treesitter")
local fixture_path = vim.fn.fnamemodify("tests/fixtures/TestCodeunit.al", ":p")

local al_parser_available = pcall(vim.treesitter.language.inspect, "al")

local function skip_without_grammar()
    if not al_parser_available then
        pending("AL treesitter grammar not installed")
        return true
    end
end

describe("neotest-al.discovery.treesitter", function()
    describe("discover_positions", function()
        it("returns a Tree for a test file", function()
            if skip_without_grammar() then return end
            local tree = treesitter.discover_positions(fixture_path)
            assert.is_not_nil(tree)
        end)

        it("root node is type=file with the codeunit name", function()
            if skip_without_grammar() then return end
            local tree = treesitter.discover_positions(fixture_path)
            local root = tree:data()
            assert.are.equal("file", root.type)
            assert.are.equal("My Test Codeunit", root.name)
        end)

        it("finds exactly two test procedures", function()
            if skip_without_grammar() then return end
            local tree = treesitter.discover_positions(fixture_path)
            assert.are.equal(2, #tree:children())
        end)

        it("test node names match [Test] procedure names", function()
            if skip_without_grammar() then return end
            local tree = treesitter.discover_positions(fixture_path)
            local names = vim.tbl_map(function(c) return c:data().name end, tree:children())
            assert.is_truthy(vim.tbl_contains(names, "Test_WhenX_ShouldY"))
            assert.is_truthy(vim.tbl_contains(names, "AnotherTest_WhenA_ShouldB"))
        end)

        it("does not include non-[Test] procedures", function()
            if skip_without_grammar() then return end
            local tree = treesitter.discover_positions(fixture_path)
            local names = vim.tbl_map(function(c) return c:data().name end, tree:children())
            assert.is_falsy(vim.tbl_contains(names, "HelperProcedure"))
        end)

        it("test node id is path::name", function()
            if skip_without_grammar() then return end
            local tree = treesitter.discover_positions(fixture_path)
            local node = tree:children()[1]:data()
            assert.are.equal(fixture_path .. "::" .. node.name, node.id)
        end)
    end)

    describe("invalidate", function()
        it("is a no-op and never errors", function()
            assert.has_no.errors(function()
                treesitter.invalidate(1)
                treesitter.invalidate(nil)
                treesitter.invalidate()
            end)
        end)
    end)
end)
