describe("neotest-al.runner.lsp.dirty", function()
    local dirty

    before_each(function()
        package.loaded["neotest-al.runner.lsp.dirty"] = nil
        dirty = require("neotest-al.runner.lsp.dirty")
    end)

    it("is_dirty returns true for a workspace that has never been published", function()
        assert.is_true(dirty.is_dirty("/workspace/project"))
    end)

    it("is_dirty returns false after mark_clean", function()
        dirty.mark_clean("/workspace/project")
        assert.is_false(dirty.is_dirty("/workspace/project"))
    end)

    it("is_dirty returns true again after mark_dirty", function()
        dirty.mark_clean("/workspace/project")
        dirty.mark_dirty("/workspace/project")
        assert.is_true(dirty.is_dirty("/workspace/project"))
    end)

    it("mark_dirty on an untracked workspace does not error", function()
        assert.has_no.errors(function()
            dirty.mark_dirty("/workspace/unknown")
        end)
        assert.is_true(dirty.is_dirty("/workspace/unknown"))
    end)

    it("mark_clean on an untracked workspace does not error", function()
        assert.has_no.errors(function()
            dirty.mark_clean("/workspace/unknown2")
        end)
        assert.is_false(dirty.is_dirty("/workspace/unknown2"))
    end)

    it("tracking is independent per workspace root", function()
        dirty.mark_clean("/workspace/a")
        dirty.mark_clean("/workspace/b")
        dirty.mark_dirty("/workspace/a")
        assert.is_true(dirty.is_dirty("/workspace/a"))
        assert.is_false(dirty.is_dirty("/workspace/b"))
    end)
end)
