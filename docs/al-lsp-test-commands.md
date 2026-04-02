# AL LSP Test Commands: Discovery and Execution

This guide documents the AL Language Server Protocol (LSP) commands for discovering and running tests, as observed from AL extension traces (version 18.0.2242655).

---

## Overview of the Message Flow

```
Client                                    AL Language Server
  |                                              |
  |                          al/updateTests ---- |  (pushed on init, contains full test tree)
  |                                              |
  |-- al/discoverTests -----------------------> |  (called per projectsLoadedNotification)
  |<-- al/projectsLoadedNotification ---------- |  (repeated as refs load)
  |<-- Result: test tree ---------------------- |
  |                          al/updateTests ---- |  (pushed again ~3s after last response)
  |                                              |
  |-- al/runTests ---------------------------> |
  |<-- al/testExecutionMessage (stream) ------- |  (build output)
  |<-- al/testMethodStart --------------------- |  (codeunit start, name="")
  |<-- al/testMethodStart --------------------- |  (individual test start)
  |<-- al/testMethodFinish -------------------- |  (individual test finish)
  |<-- al/testMethodFinish -------------------- |  (codeunit finish, name="")
  |<-- al/runTests response (no result) ------- |
  |<-- al/testRunComplete --------------------- |
```

---

## Prerequisites

Before sending test commands the project closure must be loaded. Poll with:

### `al/hasProjectClosureLoadedRequest`

**Direction:** Client → Server (request)

```json
{
  "workspacePath": "c:\\path\\to\\workspace"
}
```

**Response:**

```json
{ "loaded": true }
```

Only proceed with test discovery once `loaded` is `true`.

---

## Test Discovery

The AL server uses **two complementary mechanisms** for test data. Understanding both is important for a correct implementation.

---

### `al/updateTests` (server-initiated notification)

**Direction:** Server → Client (notification, no request needed)

The server **proactively pushes** the full test tree at two points:

1. **On LSP initialization** — before the client has called anything, the server pushes the current test tree as soon as it finishes loading.
2. **After project reload** — approximately 3 seconds after the final `al/discoverTests` response, as a consolidated final push.

This is the primary update/invalidation signal. Clients should always update their cache when `al/updateTests` arrives.

**Params:**

```json
{
  "testItems": [
    {
      "name": "My App - Test",
      "appId": "1c350336-8dcb-42db-8c2f-b33d56c5e527",
      "scope": 0,
      "children": [
        {
          "name": "My Codeunit Tests",
          "appId": "1c350336-8dcb-42db-8c2f-b33d56c5e527",
          "codeunitId": 69001,
          "scope": 1,
          "location": {
            "source": "file:///c:/path/to/MyTests.Codeunit.al",
            "range": {
              "start": { "line": 0, "character": 15 },
              "end":   { "line": 0, "character": 44 }
            }
          },
          "children": [
            {
              "name": "MyTest_WhenCondition_ShouldDoX",
              "appId": "1c350336-8dcb-42db-8c2f-b33d56c5e527",
              "codeunitId": 69001,
              "scope": 2,
              "location": {
                "source": "file:///c:/path/to/MyTests.Codeunit.al",
                "range": {
                  "start": { "line": 27, "character": 14 },
                  "end":   { "line": 27, "character": 43 }
                }
              }
            }
          ]
        }
      ]
    }
  ]
}
```

The `testItems` array has the same tree structure as the `al/discoverTests` response, wrapped one level deeper.

**`scope` values at the codeunit level:**

| Value | Meaning                    |
|-------|----------------------------|
| `0`   | App root node              |
| `1`   | Codeunit level             |
| `2`   | Individual test method     |

---

### `al/discoverTests` (request/response)

**Direction:** Client → Server (request)

**Params:** `{}` (empty object)

Called **reactively in response to each `al/projectsLoadedNotification`**. The server returns the full test tree directly in the response. Multiple calls are made — once per project reference as they finish loading.

**Response — the test tree:**

The result is a plain array of app nodes (same shape as `al/updateTests.testItems` but not wrapped):

```json
[
  {
    "name": "My App - Test",
    "appId": "1c350336-8dcb-42db-8c2f-b33d56c5e527",
    "children": [
      {
        "name": "My Codeunit Tests",
        "appId": "1c350336-8dcb-42db-8c2f-b33d56c5e527",
        "codeunitId": 69001,
        "children": [
          {
            "name": "MyTest_WhenCondition_ShouldDoX",
            "appId": "1c350336-8dcb-42db-8c2f-b33d56c5e527",
            "codeunitId": 69001,
            "scope": 2,
            "location": {
              "source": "file:///c:/path/to/MyTests.Codeunit.al",
              "range": {
                "start": { "line": 27, "character": 14 },
                "end":   { "line": 27, "character": 43 }
              }
            }
          }
        ]
      }
    ]
  }
]
```

**Key fields:**

| Field        | Description                                                      |
|--------------|------------------------------------------------------------------|
| `name`       | Display name of the app, codeunit, or test method               |
| `appId`      | GUID of the AL app                                               |
| `codeunitId` | Integer object ID of the test codeunit                          |
| `scope`      | Test scope; `2` = individual test method                        |
| `location`   | Source file URI and zero-based line/character range of the test |

The `location.range` points to the test method's procedure name token, not the full body.

**Important:** If `al/discoverTests` is called outside the reactive `al/projectsLoadedNotification` flow (e.g. as a cold-start probe), the response may be empty `{"id": N, "jsonrpc": "2.0"}`. In that case, wait for the server to push `al/updateTests` instead.

**JSON-RPC quirk:** The AL server sends responses with `"error": null` alongside a valid `result`. Neovim's LSP layer has an assertion `assert(type(decoded.error) == 'table')` that fires for `vim.NIL` (how JSON null decodes). The response callback is never called if this assertion fires. Clients must normalize `"error": null` to no error field before Neovim processes the body.

---

### `al/projectsLoadedNotification` (server-initiated notification)

Fired incrementally as each project reference finishes loading. Clients should call `al/discoverTests` immediately on receipt.

```json
{
  "projects": [
    "c:/path/to/Test"
  ]
}
```

A typical startup fires this 2–3 times:
1. When the first project (e.g. Cloud) loads
2. When the second project (e.g. Test) loads
3. When all project references are confirmed loaded

---

### `al/refreshExplorerObjects` (server-initiated notification)

No parameters. Signals that the object explorer UI should refresh. Arrives after the final `al/discoverTests` response.

---

### Observed discovery sequence (from VS Code trace)

```
← al/updateTests { testItems: [...] }          // pushed on init, ~10:01:39

← al/projectsLoadedNotification { projects: ["Cloud"] }
→ al/discoverTests {}
← Result: [ full test tree ]                   // ~987ms

← al/projectsLoadedNotification { projects: ["Test"] }
→ al/discoverTests {}
← Result: [ full test tree ]                   // ~1045ms

← al/projectsLoadedNotification { projects: ["Cloud", "Test"] }
→ al/discoverTests {}
← al/refreshExplorerObjects
← Result: [ full test tree ]                   // ~1877ms

// ~3s later:
← al/updateTests { testItems: [...] }          // consolidated final push
```

---

## Code Lens (Optional — Editor Integration)

### `textDocument/codeLens`

**Direction:** Client → Server (request)

Returns code lens decorations for a test file. Each lens item has a `data` object:

```json
{
  "range": { "start": { "line": 18, "character": 14 }, "end": { "line": 18, "character": 56 } },
  "data": {
    "fileName": "c:/path/to/MyTests.Codeunit.al",
    "version": "2026-04-01T20:53:01.2907409Z-11134-0",
    "type": 0
  }
}
```

**`data.type` values:**

| Value | Meaning                                                     |
|-------|-------------------------------------------------------------|
| `0`   | Codeunit-level lens (run all / manage codeunit)            |
| `2`   | Individual test method lens (run single test)              |

Test method lines emit **two** lenses: one with `type 0` (run from codeunit context) and one with `type 2` (run individually). Codeunit declaration lines emit only `type 0`.

---

## Run Tests

### `al/runTests`

**Direction:** Client → Server (request)

Builds the test project, publishes it to the server, and executes the specified tests.

**Full request params:**

```json
{
  "configuration": {
    "type": "al",
    "request": "launch",
    "name": "dev",
    "server": "https://your-bc-server.example.com",
    "port": 443,
    "serverInstance": "<server-instance-guid-or-name>",
    "tenant": "default",
    "authentication": "UserPassword",
    "breakOnError": "None",
    "schemaUpdateMode": "Synchronize",
    "disableHttpRequestTimeout": true
  },
  "Tests": [
    {
      "name": "MyTest_WhenCondition_ShouldDoX",
      "appId": "1c350336-8dcb-42db-8c2f-b33d56c5e527",
      "codeunitId": 69001,
      "scope": 2,
      "location": {
        "source": "file:///c:/path/to/MyTests.Codeunit.al",
        "range": {
          "start": { "line": 27, "character": 14 },
          "end":   { "line": 27, "character": 43 }
        }
      }
    }
  ],
  "SkipPublish": false,
  "VSCodeExtensionVersion": "18.0.2242655",
  "CoverageMode": "none",
  "Args": []
}
```

**Key fields:**

| Field                    | Type    | Description                                                        |
|--------------------------|---------|--------------------------------------------------------------------|
| `configuration`          | object  | Mirrors a `launch.json` configuration entry                       |
| `Tests`                  | array   | List of test method objects to run (from discovery)               |
| `SkipPublish`            | boolean | Skip build+publish step if the app is already deployed            |
| `VSCodeExtensionVersion` | string  | AL extension version string                                        |
| `CoverageMode`           | string  | `"none"` or `"statement"` for code coverage collection           |
| `Args`                   | array   | Additional CLI arguments (usually empty)                          |

**Running a full codeunit:** Pass all test method objects from that codeunit in the `Tests` array.

**Running a single test:** Pass only the single test method object.

**Response:** No result value. Fires after all tests complete.

---

## Test Execution Events

### `al/testExecutionMessage` (notification)

Streaming build and compiler output. Each message is a timestamped string:

```json
"[2026-04-02 00:04:49.59] Preparing to build and publish projects...\r\n"
```

Messages include:
- Build start/progress
- Compiler warnings and errors (format: `file(line,col): severity code: message`)
- Publication status

### `al/testMethodStart` (notification)

Fired twice per codeunit: once at codeunit start (empty name) and once per test method.

```json
{ "name": "",       "codeunitId": 69002 }   // codeunit start (OnRun trigger)
{ "name": "MyTest", "codeunitId": 69002 }   // test method start
```

### `al/testMethodFinish` (notification)

Fired for each test method completion and once more for the codeunit itself:

```json
{
  "name": "MyTest_WhenCondition_ShouldDoX",
  "codeunitId": 69002,
  "status": 0,
  "message": "",
  "duration": 950
}
```

**`status` values:**

| Value | Meaning  |
|-------|----------|
| `0`   | Passed   |
| `1`   | Failed   |
| `2`   | Skipped  |

- `message`: Error message on failure, empty string on success.
- `duration`: Execution time in milliseconds.
- An empty-name finish at the end of a codeunit gives total wall-clock time for that codeunit run.

### `al/testRunComplete` (notification)

No parameters. Signals that the entire `al/runTests` session is done. Always follows the `al/runTests` response.

---

## Supporting Notifications

### `workspace/didChangeWatchedFiles`

The coverage file (`<workspace>/.coverage/coverage.json`) is updated after a run with `CoverageMode: "statement"`.

### `al/progressNotification`

Emitted during project closure resolution:

```json
{
  "percent": 0,
  "message": "Resolving reference closure consisting of '2' project references...",
  "cancel": false,
  "owner": 0
}
```

---

## Complete Sequence Example

```
// On LSP startup — server pushes test tree before client requests anything
← al/updateTests { testItems: [ { name: "App", children: [...] } ] }

// Project references load incrementally
← al/projectsLoadedNotification { projects: ["Cloud"] }
→ al/discoverTests {}
← Result: [ { name: "App", children: [...] } ]

← al/projectsLoadedNotification { projects: ["Cloud", "Test"] }
→ al/discoverTests {}
← al/refreshExplorerObjects
← Result: [ { name: "App", children: [...] } ]

// Server pushes consolidated final state ~3s later
← al/updateTests { testItems: [ { name: "App", children: [...] } ] }

// Run a specific test
→ al/runTests { configuration: {...}, Tests: [{ name: "...", codeunitId: 69001, ... }] }
← al/testExecutionMessage "[...] Preparing to build..."
← al/testMethodStart { name: "", codeunitId: 69001 }
← al/testMethodStart { name: "MyTest", codeunitId: 69001 }
← al/testMethodFinish { name: "MyTest", codeunitId: 69001, status: 0, duration: 14 }
← al/testMethodFinish { name: "", codeunitId: 69001, status: 0, duration: 14 }
← al/runTests response (no result)
← al/testRunComplete
```

---

## Implementation Notes

- **al/updateTests is the primary data source.** Register a handler for it at startup so the init-time push is captured before any explicit request is made.
- **al/discoverTests is reactive.** Call it in response to each `al/projectsLoadedNotification`. Do not call it in isolation expecting a response — it may return empty if called outside that reactive flow.
- **al/updateTests is the update signal.** When it arrives, replace the cached test tree entirely. This is how the server communicates both initial data and subsequent changes (e.g. after a build, when tests are added or removed).
- **location data** from either mechanism can be passed directly into `al/runTests` without transformation.
- **SkipPublish: true** speeds up re-runs when the app has not changed since the last publish.
- **JSON null in responses** (`"error": null` alongside a valid `result`) is a known AL server behaviour. Neovim's LSP layer asserts `type(error) == 'table'`, which fails for `vim.NIL`. Normalize before processing.
