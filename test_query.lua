-- Run with: :source C:\Users\arbo\Documents\source\repos\neotest-al\test_query.lua
-- Make sure an AL test codeunit is the current buffer first

local path = vim.fn.expand("%:p")
local content = vim.fn.join(vim.fn.readfile(path), "\n")

print("=== Testing treesitter query on: " .. path)

-- 1. Check the parser works at all
local ok, parser = pcall(vim.treesitter.get_string_parser, content, "al")
if not ok then
    print("ERROR: Could not get AL parser: " .. tostring(parser))
    return
end

local tree = parser:parse()[1]
local root = tree:root()
print("Root node type: " .. root:type() .. " (children: " .. root:child_count() .. ")")

-- 2. Try a bare "all procedures" query first
print("\n--- All procedures ---")
local ok2, all_procs = pcall(vim.treesitter.query.parse, "al", [[(procedure name: (identifier) @name)]])
if not ok2 then
    print("ERROR parsing procedure query: " .. tostring(all_procs))
else
    local count = 0
    for id, node in all_procs:iter_captures(root, content) do
        count = count + 1
        print("  procedure: " .. vim.treesitter.get_node_text(node, content))
    end
    if count == 0 then print("  (none found)") end
end

-- 3. Try all attribute_items
print("\n--- All attribute_items ---")
local ok3, all_attrs = pcall(vim.treesitter.query.parse, "al", [[(attribute_item) @attr]])
if not ok3 then
    print("ERROR parsing attribute query: " .. tostring(all_attrs))
else
    local count = 0
    for id, node in all_attrs:iter_captures(root, content) do
        count = count + 1
        print("  attr: " .. vim.treesitter.get_node_text(node, content))
    end
    if count == 0 then print("  (none found)") end
end

-- 4. Try the full neotest query
print("\n--- Full neotest query ---")
local full_query_str = [[
    (_
      (attribute_item
        attribute: (attribute_content
          name: (identifier) @_attr (#eq? @_attr "Test")))
      (procedure
        name: (identifier) @test.name) @test.definition
    )
]]
local ok4, full_query = pcall(vim.treesitter.query.parse, "al", full_query_str)
if not ok4 then
    print("ERROR parsing full query: " .. tostring(full_query))
else
    local count = 0
    for pattern, match, metadata in full_query:iter_matches(root, content, 0, -1, { all = true }) do
        for id, nodes in pairs(match) do
            local name = full_query.captures[id]
            if name == "test.name" then
                local node = type(nodes) == "table" and nodes[1] or nodes
                count = count + 1
                print("  test: " .. vim.treesitter.get_node_text(node, content))
            end
        end
    end
    if count == 0 then print("  (none found)") end
end

print("\n=== Done ===")
