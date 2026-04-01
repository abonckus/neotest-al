local M = {}

function M.is_test_file(file_path)
    if not vim.endswith(file_path, ".al") then
        return false
    end

    local f = io.open(file_path, "r")
    if not f then
        return false
    end
    local prefix = f:read(1024)
    f:close()

    if prefix and prefix:match("[Ss]ubtype%s*=%s*[Tt]est") then
        return true
    end

    return false
end

function M.position_id(position, parents)
    print("Generating position ID for " .. position.name)
    local original_id = position.path
    local has_parent_class = false
    local sep = "::"

    -- Build the original ID from the parents, changing the separator to "+" if any nodes are nested classes
    for _, node in ipairs(parents) do
        if has_parent_class and node.is_class then
            sep = "+"
        end

        if node.is_class then
            has_parent_class = true
        end

        original_id = original_id .. sep .. node.name
    end

    -- Add the final leaf nodes name to the ID, again changing the separator to "+" if it is a nested class
    sep = "::"
    if has_parent_class and position.is_class then
        sep = "+"
    end
    original_id = original_id .. sep .. position.name

    return original_id
end

return M
