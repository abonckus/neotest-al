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

        it("returns nil for a path that shares root prefix but is a different directory", function()
            local mock = { id = 1, root_dir = "/workspace", name = "al_ls" }
            local orig = vim.lsp.get_clients
            vim.lsp.get_clients = function() return { mock } end

            assert.is_nil(lsp._find_client("/workspace2/File.al"))

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
            local fpath = lsp._norm(vim.uri_to_fname(uri))
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

    -- ── discover_positions ────────────────────────────────────────────────────
    describe("discover_positions", function()
        local fixture_path = vim.fn.fnamemodify("tests/fixtures/TestCodeunit.al", ":p")
        local fixture_uri  = vim.uri_from_fname(fixture_path)

        local function make_mock_client(id, root, response)
            return {
                id       = id,
                root_dir = root,
                request  = function(self, method, params, cb)
                    vim.schedule(function() cb(nil, response) end)
                    return true, 1
                end,
            }
        end

        local function mock_response(uri)
            return {
                {
                    name     = "Test App",
                    children = {
                        {
                            name       = "My Test Codeunit",
                            codeunitId = 50100,
                            children   = {
                                {
                                    name     = "Test_WhenX_ShouldY",
                                    location = {
                                        source  = uri,
                                        range   = {
                                            start   = { line = 5, character = 14 },
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

        -- Helper: run an async function inside nio.run and wait for it
        local function run_async(fn)
            local nio = require("nio")
            local result, err, completed = nil, nil, false
            nio.run(function()
                local ok, val = pcall(fn)
                if ok then result = val else err = val end
                completed = true
            end)
            vim.wait(5000, function() return completed end, 10)
            if err then error(err, 2) end
            return result
        end

        it("returns nil when no al_ls client exists", function()
            local orig = vim.lsp.get_clients
            vim.lsp.get_clients = function() return {} end

            local result = run_async(function()
                return lsp.discover_positions(fixture_path)
            end)

            vim.lsp.get_clients = orig
            assert.is_nil(result)
        end)

        it("returns nil when LSP has no tests for the file", function()
            local root   = vim.fn.fnamemodify("tests/fixtures", ":p")
            local client = make_mock_client(88, root, {})
            local orig   = vim.lsp.get_clients
            vim.lsp.get_clients = function() return { client } end

            local result = run_async(function()
                return lsp.discover_positions(fixture_path)
            end)

            vim.lsp.get_clients = orig
            lsp.invalidate(88)
            assert.is_nil(result)
        end)

        it("returns a Tree when LSP reports tests for the file", function()
            local root   = vim.fn.fnamemodify("tests/fixtures", ":p")
            local client = make_mock_client(99, root, mock_response(fixture_uri))
            local orig   = vim.lsp.get_clients
            vim.lsp.get_clients = function() return { client } end

            local tree = run_async(function()
                return lsp.discover_positions(fixture_path)
            end)

            vim.lsp.get_clients = orig
            lsp.invalidate(99)

            assert.is_not_nil(tree)
            local root_node = tree:data()
            assert.are.equal("file", root_node.type)
            assert.are.equal("My Test Codeunit", root_node.name)
        end)

        it("builds one test child per LSP test item", function()
            local root   = vim.fn.fnamemodify("tests/fixtures", ":p")
            local client = make_mock_client(100, root, mock_response(fixture_uri))
            local orig   = vim.lsp.get_clients
            vim.lsp.get_clients = function() return { client } end

            local tree = run_async(function()
                return lsp.discover_positions(fixture_path)
            end)

            vim.lsp.get_clients = orig
            lsp.invalidate(100)

            assert.are.equal(1, #tree:children())
            local test_node = tree:children()[1]:data()
            assert.are.equal("test", test_node.type)
            assert.are.equal("Test_WhenX_ShouldY", test_node.name)
            assert.are.equal(fixture_path .. "::" .. "Test_WhenX_ShouldY", test_node.id)
            assert.are.same({ 5, 14, 5, 28 }, test_node.range)
        end)

        it("serves subsequent calls from cache without re-requesting", function()
            local request_count = 0
            local root = vim.fn.fnamemodify("tests/fixtures", ":p")
            local client = {
                id       = 101,
                root_dir = root,
                request  = function(self, method, params, cb)
                    request_count = request_count + 1
                    vim.schedule(function() cb(nil, mock_response(fixture_uri)) end)
                    return true, 1
                end,
            }
            local orig = vim.lsp.get_clients
            vim.lsp.get_clients = function() return { client } end

            run_async(function() lsp.discover_positions(fixture_path) end)
            run_async(function() lsp.discover_positions(fixture_path) end)

            vim.lsp.get_clients = orig
            lsp.invalidate(101)

            assert.are.equal(1, request_count)
        end)

        it("re-fetches after invalidate", function()
            local request_count = 0
            local root = vim.fn.fnamemodify("tests/fixtures", ":p")
            local client = {
                id       = 102,
                root_dir = root,
                request  = function(self, method, params, cb)
                    request_count = request_count + 1
                    vim.schedule(function() cb(nil, mock_response(fixture_uri)) end)
                    return true, 1
                end,
            }
            local orig = vim.lsp.get_clients
            vim.lsp.get_clients = function() return { client } end

            run_async(function() lsp.discover_positions(fixture_path) end)
            lsp.invalidate(102)
            run_async(function() lsp.discover_positions(fixture_path) end)

            vim.lsp.get_clients = orig
            lsp.invalidate(102)

            assert.are.equal(2, request_count)
        end)

        it("populates raw_tree directly from al/discoverTests response without al/updateTests", function()
            -- This client returns data from al/discoverTests but never fires al/updateTests.
            -- The old code ignores the response and waits 10 s for al/updateTests → times out.
            -- The new code must use the response directly.
            local root = vim.fn.fnamemodify("tests/fixtures", ":p")
            local client = {
                id       = 150,
                root_dir = root,
                request  = function(self, method, params, cb)
                    if method == "al/discoverTests" then
                        vim.schedule(function() cb(nil, mock_response(fixture_uri)) end)
                    end
                    return true, 1
                end,
            }
            local orig = vim.lsp.get_clients
            vim.lsp.get_clients = function() return { client } end

            local tree = run_async(function()
                return lsp.discover_positions(fixture_path)
            end)

            vim.lsp.get_clients = orig
            lsp.invalidate(150)

            assert.is_not_nil(tree,
                "expected discover_positions to use al/discoverTests response directly")
            assert.are.equal("My Test Codeunit", tree:data().name)
        end)

        it("retries al/discoverTests when server returns empty response", function()
            local call_count = 0
            local root = vim.fn.fnamemodify("tests/fixtures", ":p")
            local client = {
                id       = 160,
                root_dir = root,
                request  = function(self, method, params, cb)
                    if method == "al/discoverTests" then
                        call_count = call_count + 1
                        if call_count == 1 then
                            vim.schedule(function() cb(nil, {}) end)       -- first: not ready
                        else
                            vim.schedule(function() cb(nil, mock_response(fixture_uri)) end)
                        end
                    end
                    return true, 1
                end,
            }
            local orig = vim.lsp.get_clients
            vim.lsp.get_clients = function() return { client } end

            local tree = run_async(function()
                return lsp.discover_positions(fixture_path)
            end)

            vim.lsp.get_clients = orig
            lsp.invalidate(160)

            assert.is_not_nil(tree, "expected retry to succeed on second attempt")
            assert.are.equal("My Test Codeunit", tree:data().name)
            assert.are.equal(2, call_count)
        end)

        it("fires al/discoverTests immediately on al/projectsLoadedNotification", function()
            local requests_fired = {}
            local mock_client = {
                id       = 510,
                root_dir = "/workspace",
                request  = function(self, method, params, cb)
                    table.insert(requests_fired, method)
                    vim.schedule(function() cb(nil, {}) end)
                    return true, 1
                end,
            }
            local orig_by_id = vim.lsp.get_client_by_id
            vim.lsp.get_client_by_id = function(id)
                if id == 510 then return mock_client end
            end

            local handler = vim.lsp.handlers["al/projectsLoadedNotification"]
            assert.is_not_nil(handler, "handler must be registered")
            handler(nil, { projects = {} }, { client_id = 510 }, nil)

            vim.wait(1000, function() return #requests_fired > 0 end, 10)

            vim.lsp.get_client_by_id = orig_by_id
            lsp.invalidate(510)

            assert.is_true(vim.tbl_contains(requests_fired, "al/discoverTests"),
                "expected al/discoverTests to be fired")
        end)

        it("populates raw_tree from al/discoverTests response on al/projectsLoadedNotification", function()
            local uri = "file:///workspace/ReactiveTest.al"
            local response = {
                {
                    name     = "Reactive App",
                    children = {
                        {
                            name       = "Reactive CU",
                            codeunitId = 600,
                            children   = {
                                {
                                    name     = "ReactiveTest_ShouldWork",
                                    location = {
                                        source  = uri,
                                        range   = {
                                            start   = { line = 3, character = 4 },
                                            ["end"] = { line = 3, character = 28 },
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            }

            local mock_client = {
                id       = 511,
                root_dir = "/workspace",
                request  = function(self, method, params, cb)
                    if method == "al/discoverTests" then
                        vim.schedule(function() cb(nil, response) end)
                    end
                    return true, 1
                end,
            }
            local orig_by_id = vim.lsp.get_client_by_id
            vim.lsp.get_client_by_id = function(id)
                if id == 511 then return mock_client end
            end

            local handler = vim.lsp.handlers["al/projectsLoadedNotification"]
            handler(nil, { projects = {} }, { client_id = 511 }, nil)

            local fpath = lsp._norm(vim.uri_to_fname(uri))
            vim.wait(1000, function() return lsp.get_items(fpath) ~= nil end, 10)

            vim.lsp.get_client_by_id = orig_by_id
            local entry = lsp.get_items(fpath)
            lsp.invalidate(511)

            assert.is_not_nil(entry, "expected get_items to return data from reactive discoverTests")
            assert.are.equal("Reactive CU", entry.codeunit_name)
            assert.are.equal(600, entry.codeunit_id)
            assert.are.equal(1, #entry.tests)
            assert.are.equal("ReactiveTest_ShouldWork", entry.tests[1].name)
        end)

        after_each(function()
            vim.lsp.handlers["al/projectsLoadedNotification"] = nil
        end)
    end)

    -- ── get_items ─────────────────────────────────────────────────────────────
    describe("get_items", function()
        it("returns nil when path is not in cache", function()
            lsp.invalidate()
            assert.is_nil(lsp.get_items("/workspace/File.al"))
        end)

        it("returns cached entry with correct shape", function()
            local uri   = "file:///workspace/File.al"
            local fpath = vim.fs.normalize(vim.uri_to_fname(uri))

            -- Seed the cache by calling _index_by_file via the al/updateTests handler
            local ctx = { client_id = 200 }
            vim.lsp.handlers["al/updateTests"](nil, {
                testItems = {
                    {
                        name     = "Test App",
                        children = {
                            {
                                name       = "My Codeunit",
                                codeunitId = 50200,
                                children   = {
                                    {
                                        name     = "Test_Foo",
                                        appId    = "abc-123",
                                        codeunitId = 50200,
                                        scope    = 2,
                                        location = {
                                            source = uri,
                                            range  = {
                                                start  = { line = 1, character = 0 },
                                                ["end"] = { line = 1, character = 8 },
                                            },
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            }, ctx, nil)

            -- The handler defers cache population via vim.schedule; pump the
            -- event loop once so the scheduled callback runs before we read.
            vim.wait(100, function() return lsp.get_items(fpath) ~= nil end, 10)

            local entry = lsp.get_items(fpath)
            assert.is_not_nil(entry)
            assert.are.equal("My Codeunit", entry.codeunit_name)
            assert.are.equal(50200, entry.codeunit_id)
            assert.are.equal(1, #entry.tests)
            assert.are.equal("Test_Foo", entry.tests[1].name)

            lsp.invalidate(200)
        end)
    end)

    -- ── get_client ────────────────────────────────────────────────────────────
    describe("get_client", function()
        it("returns nil when no al_ls clients exist", function()
            local orig = vim.lsp.get_clients
            vim.lsp.get_clients = function() return {} end
            assert.is_nil(lsp.get_client("/workspace/File.al"))
            vim.lsp.get_clients = orig
        end)

        it("returns client whose root_dir is a prefix of the path", function()
            local mock = { id = 1, root_dir = "/workspace", name = "al_ls" }
            local orig = vim.lsp.get_clients
            vim.lsp.get_clients = function() return { mock } end
            assert.are.equal(mock, lsp.get_client("/workspace/Src/File.al"))
            vim.lsp.get_clients = orig
        end)
    end)

    -- ── is_test_file ──────────────────────────────────────────────────────────
    describe("is_test_file", function()
        -- Seed raw_tree + test_file_set via the al/updateTests handler.
        -- The handler uses vim.schedule so we pump the event loop with vim.wait.
        local function seed(client_id, uri)
            vim.lsp.handlers["al/updateTests"](nil, {
                testItems = {
                    {
                        name = "App",
                        children = {
                            {
                                name       = "TestCU",
                                codeunitId = 500,
                                children   = {
                                    {
                                        name     = "Test_Foo",
                                        location = {
                                            source = uri,
                                            range  = {
                                                start   = { line = 1, character = 0 },
                                                ["end"] = { line = 1, character = 8 },
                                            },
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            }, { client_id = client_id }, nil)
            vim.wait(200, function() return false end)
        end

        before_each(function() lsp.invalidate() end)

        it("returns false when no LSP data is loaded", function()
            assert.is_false(lsp.is_test_file("/workspace/File.al"))
        end)

        it("returns true for a path that has tests", function()
            local uri   = "file:///workspace/TestCU.al"
            local fpath = lsp._norm(vim.uri_to_fname(uri))
            seed(400, uri)
            assert.is_true(lsp.is_test_file(fpath))
            lsp.invalidate(400)
        end)

        it("returns false for a path with no tests", function()
            local uri   = "file:///workspace/TestCU.al"
            seed(401, uri)
            local other = lsp._norm(vim.uri_to_fname("file:///workspace/Other.al"))
            assert.is_false(lsp.is_test_file(other))
            lsp.invalidate(401)
        end)

        it("returns false after the client is invalidated", function()
            local uri   = "file:///workspace/TestCU.al"
            local fpath = lsp._norm(vim.uri_to_fname(uri))
            seed(402, uri)
            lsp.invalidate(402)
            assert.is_false(lsp.is_test_file(fpath))
        end)

        it("returns false after invalidate() with no args", function()
            local uri   = "file:///workspace/TestCU.al"
            local fpath = lsp._norm(vim.uri_to_fname(uri))
            seed(403, uri)
            lsp.invalidate()
            assert.is_false(lsp.is_test_file(fpath))
        end)
    end)
end)
