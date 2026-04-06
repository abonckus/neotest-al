local Tree = require("neotest.types").Tree

---@type neotest-al.Discovery
local M = {}
M.name = "treesitter"

local QUERY = [[
    (_
      (attribute_item)*
      .
      (attribute_item
        attribute: (attribute_content
          name: (identifier) @_attr (#eq? @_attr "Test")))
      .
      (attribute_item)*
      .
      (procedure
        name: (identifier) @test.name) @test.definition
    )
]]

---@async
---@param path string
---@return neotest.Tree|nil
function M.discover_positions(path)
    local lines = vim.fn.readfile(path)
    local content = table.concat(lines, "\n")

    local parser = vim.treesitter.get_string_parser(content, "al")
    local parsed_tree = parser:parse()[1]
    local root = parsed_tree:root()

    local query = vim.treesitter.query.parse("al", QUERY)

    local name_id, def_id
    for id, name in ipairs(query.captures) do
        if name == "test.name" then
            name_id = id
        end
        if name == "test.definition" then
            def_id = id
        end
    end

    local codeunit_name = content:match('[Cc]odeunit%s+%d+%s+"([^"]+)"')
        or content:match("[Cc]odeunit%s+%d+%s+([%w_%.%-]+)")

    local pos_list = {
        {
            type = "file",
            path = path,
            name = codeunit_name or vim.fn.fnamemodify(path, ":t"),
            id = path,
            range = { 0, 0, #lines - 1, 0 },
        },
    }

    local seen = {}
    for _, match in query:iter_matches(root, content, 0, -1, { all = true }) do
        local name_nodes = match[name_id]
        local def_nodes = match[def_id]
        if name_nodes and def_nodes then
            local name_node = type(name_nodes) == "table" and name_nodes[1] or name_nodes
            local def_node = type(def_nodes) == "table" and def_nodes[1] or def_nodes
            local sr, sc, er, ec = def_node:range()
            if not seen[sr] then
                seen[sr] = true
                local test_name = vim.treesitter.get_node_text(name_node, content)
                table.insert(pos_list, {
                    type = "test",
                    path = path,
                    name = test_name,
                    id = path .. "::" .. test_name,
                    range = { sr, sc, er, ec },
                })
            end
        end
    end

    return Tree.from_list(pos_list, function(pos)
        return pos.id
    end)
end

---@param _client_id? integer  unused — treesitter has no cache
function M.invalidate(_client_id)
    -- no-op
end

---@param path string
---@return boolean
--- Reads the first 1 KB of the file and checks for an AL Test subtype declaration.
function M.is_test_file(path)
    if not vim.endswith(path, ".al") then
        return false
    end
    local f = io.open(path, "r")
    if not f then
        return false
    end
    local prefix = f:read(1024)
    f:close()
    return prefix ~= nil and prefix:match("[Ss]ubtype%s*=%s*[Tt]est") ~= nil
end

return M
