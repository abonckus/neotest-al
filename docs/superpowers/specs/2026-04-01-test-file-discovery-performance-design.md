# Test File Discovery Performance

**Date:** 2026-04-01

## Problem

`is_test_file` in `lua/neotest-al/base.lua` uses `lib.files.read(file_path)` to load the entire file content before checking for `Subtype = Test`. On projects with hundreds or thousands of `.al` files, this causes unnecessary I/O.

## Design

Replace the full file read with a fixed-prefix read using `io.open` + `f:read(n)`.

**Change location:** `lua/neotest-al/base.lua`, `is_test_file` function (lines 5–16)

**Behaviour:**
- Open the file with `io.open`
- Read the first 1024 bytes
- Close the file handle
- Match `[Ss]ubtype%s*=%s*[Tt]est` against the prefix
- Return true if matched, false otherwise

`Subtype = Test` always appears in the codeunit header, before the first procedure — well within 1024 bytes for any real AL file.

## Scope

Only `is_test_file` changes. `discover_positions`, root detection, result parsing, and all other adapter behaviour are unaffected.

## Out of Scope

- Caching results across neotest runs
- Filename-based pre-filtering
- Any changes to `discover_positions`
