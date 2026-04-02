-- Backward-compatibility shim.
-- Provides a default instance of the LSP runner so existing configs that do:
--   require("neotest-al")()   -- uses default runner/lsp
-- continue to work without any changes.
return require("neotest-al.runner.lsp.init").new()
