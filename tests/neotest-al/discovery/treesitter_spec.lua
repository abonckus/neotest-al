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

    describe("get_items", function()
        it("returns nil for a non-.al file", function()
            assert.is_nil(treesitter.get_items("/some/file.txt"))
        end)

        it("returns nil when file does not exist", function()
            assert.is_nil(treesitter.get_items("/nonexistent/file.al"))
        end)

        it("returns codeunit_id parsed from the file", function()
            local result = treesitter.get_items(fixture_path)
            assert.is_not_nil(result)
            assert.are.equal(50100, result.codeunit_id)
        end)

        it("returns codeunit_name parsed from the file", function()
            local result = treesitter.get_items(fixture_path)
            assert.is_not_nil(result)
            assert.are.equal("My Test Codeunit", result.codeunit_name)
        end)

        it("returns empty tests list without grammar (degrades gracefully)", function()
            if al_parser_available then pending("grammar installed; cannot test degraded path") end
            local result = treesitter.get_items(fixture_path)
            assert.is_not_nil(result)
            assert.are.equal(0, #result.tests)
        end)

        it("returns test items with correct names when grammar available", function()
            if skip_without_grammar() then return end
            local result = treesitter.get_items(fixture_path)
            local names = vim.tbl_map(function(t) return t.name end, result.tests)
            assert.is_truthy(vim.tbl_contains(names, "Test_WhenX_ShouldY"))
            assert.is_truthy(vim.tbl_contains(names, "AnotherTest_WhenA_ShouldB"))
            assert.is_falsy(vim.tbl_contains(names, "HelperProcedure"))
        end)

        it("each test item has codeunitId, scope=2, appId, and location when grammar available", function()
            if skip_without_grammar() then return end
            local result = treesitter.get_items(fixture_path)
            assert.are.equal(2, #result.tests)
            for _, t in ipairs(result.tests) do
                assert.are.equal(50100, t.codeunitId)
                assert.are.equal(2, t.scope)
                assert.is_string(t.appId)
                assert.is_not_nil(t.location)
                assert.is_not_nil(t.location.source)
                assert.is_not_nil(t.location.range)
                assert.is_not_nil(t.location.range.start)
                assert.is_not_nil(t.location.range["end"])
            end
        end)

        it("location source is a URI", function()
            if skip_without_grammar() then return end
            local result = treesitter.get_items(fixture_path)
            assert.is_truthy(result.tests[1].location.source:match("^file://"))
        end)

        it("appId in test items comes from app.json when grammar available", function()
            if skip_without_grammar() then return end
            local tmpdir = vim.fn.tempname()
            vim.fn.mkdir(tmpdir, "p")
            local al_path = tmpdir .. "/Test.al"
            local af = io.open(al_path, "w")
            af:write('[Test]\nprocedure MyTest()\nbegin\nend;\n')
            af:close()
            -- Write a minimal AL file with codeunit declaration and app.json
            af = io.open(al_path, "w")
            af:write('codeunit 99 "Tmp"\n{\n  Subtype = Test;\n\n  [Test]\n  procedure MyTest()\n  begin\n  end;\n}\n')
            af:close()
            local aj = io.open(tmpdir .. "/app.json", "w")
            aj:write('{"id":"test-app-id-123","name":"Tmp"}')
            aj:close()

            local result = treesitter.get_items(al_path)

            os.remove(al_path)
            os.remove(tmpdir .. "/app.json")
            vim.fn.delete(tmpdir, "d")

            assert.is_not_nil(result)
            assert.are.equal(1, #result.tests)
            assert.are.equal("test-app-id-123", result.tests[1].appId)
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
