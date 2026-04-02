# Test File Discovery Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace full-file read in `is_test_file` with a fixed-prefix read to reduce I/O on large AL projects.

**Architecture:** Open the file with `io.open`, read the first 1024 bytes, close the handle, and match the existing `Subtype = Test` pattern against the prefix. No other behaviour changes.

**Tech Stack:** Lua, Neovim plugin environment

---

### Task 1: Replace full read with partial read in `is_test_file`

**Files:**
- Modify: `lua/neotest-al/base.lua:1-16`

- [ ] **Step 1: Write the failing test**

There is no existing test suite, so verify the current behaviour manually first. Open Neovim with an AL test file and confirm `is_test_file` returns true, then confirm it returns false for a non-test AL file. Note this as the baseline.

- [ ] **Step 2: Implement the change**

Replace lines 1–16 of `lua/neotest-al/base.lua` with:

```lua
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
```

Note: the `local lib = require("neotest.lib")` import at the top of the file is no longer needed by `is_test_file`. Check whether `lib` is used anywhere else in `base.lua` — it is not (only `position_id` remains, and it does not use `lib`). Remove the `require` line.

- [ ] **Step 3: Verify manually**

Reload the plugin in Neovim (`:lua package.loaded["neotest-al"] = nil`) and run neotest on a project with AL test files. Confirm test files are discovered as before.

- [ ] **Step 4: Commit**

```bash
git add lua/neotest-al/base.lua
git commit -m "perf: read only first 1024 bytes in is_test_file"
```
