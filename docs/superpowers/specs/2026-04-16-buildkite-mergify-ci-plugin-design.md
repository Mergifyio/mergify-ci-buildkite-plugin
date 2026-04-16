# Buildkite Mergify CI Plugin — Design Spec

## Overview

A Buildkite plugin that replicates the functionality of `gha-mergify-ci` (the GitHub Actions Mergify CI integration). It wraps the `mergify-cli` tool to provide JUnit test report processing, scope detection, and scope uploading for Mergify CI Insights and Merge Queue.

## Supported Actions

| Action | Description |
|--------|-------------|
| `junit-process` | Process JUnit XML files and upload to Mergify CI Insights. Detects silent test failures. |
| `scopes` | Detect which code scopes a PR touches, upload to Mergify API. |
| `scopes-git-refs` | Return merge-queue-aware base/head SHAs. |
| `scopes-upload` | Upload pre-computed scopes to Mergify API. |

`wait-jobs` from the GHA action is **not included** — Buildkite handles job dependencies natively via `depends_on`.

## Plugin Configuration

### Properties

| Property | Required | Default | Used by | Description |
|----------|----------|---------|---------|-------------|
| `action` | yes | — | all | `junit-process`, `scopes`, `scopes-git-refs`, or `scopes-upload` |
| `token` | for API calls | — | junit-process, scopes, scopes-upload | Mergify CI authentication token |
| `report_path` | for junit-process | — | junit-process | Glob path to JUnit XML files |
| `scopes` | for scopes-upload | — | scopes-upload | Comma-separated list of scopes |
| `mergify_api_url` | no | `https://api.mergify.com` | junit-process, scopes, scopes-upload | Mergify API endpoint |
| `job_name` | no | `$BUILDKITE_LABEL` | junit-process | Override job name (useful for matrix builds) |
| `mergify_config_path` | no | — | scopes, scopes-git-refs, scopes-upload | Path to `.mergify.yml` |

### Usage Examples

**junit-process** (attaches to a test step via `post-command`):
```yaml
steps:
  - label: "Run tests"
    command: pytest --junitxml=reports/junit.xml
    plugins:
      - mergify/mergify-ci#v1:
          action: junit-process
          report_path: "reports/*.xml"
          token: "${MERGIFY_CI_TOKEN}"
```

**scopes** (standalone step via `command`):
```yaml
steps:
  - label: "Detect scopes"
    plugins:
      - mergify/mergify-ci#v1:
          action: scopes
          token: "${MERGIFY_CI_TOKEN}"
```

**scopes-git-refs + scopes-upload** (two steps, data passed via meta-data):
```yaml
steps:
  - label: "Get git refs"
    key: git-refs
    plugins:
      - mergify/mergify-ci#v1:
          action: scopes-git-refs

  - label: "Upload scopes"
    depends_on: git-refs
    plugins:
      - mergify/mergify-ci#v1:
          action: scopes-upload
          token: "${MERGIFY_CI_TOKEN}"
          scopes: "backend,frontend"
```

## File Structure

```
buildkite-mergify-ci/
├── plugin.yml                 # Plugin metadata & config schema
├── hooks/
│   ├── environment            # Installs mergify-cli via uv
│   ├── command                # Dispatches: scopes, scopes-git-refs, scopes-upload
│   │                          # Falls through to user's command for junit-process
│   └── post-command           # Dispatches: junit-process
├── lib/
│   ├── shared.sh              # Common helpers (logging, config reading, meta-data)
│   ├── junit.sh               # junit-process implementation
│   └── scopes.sh              # scopes/scopes-git-refs/scopes-upload implementation
├── tests/
│   ├── junit-process.bats     # BATS tests for junit-process
│   ├── scopes.bats            # BATS tests for scope actions
│   └── helpers/
│       └── stub.bash          # Test helpers (mock buildkite-agent, mergify CLI)
├── .buildkite/
│   └── pipeline.yml           # Integration test pipeline
├── docker-compose.yml         # Mock server for integration tests
├── README.md
└── LICENSE
```

## Hook Lifecycle

### Which hook runs for which action

| Action | `environment` | `command` | `post-command` |
|--------|:---:|:---:|:---:|
| `junit-process` | install cli | executes user's `$BUILDKITE_COMMAND` (fall-through) | process & upload JUnit XML |
| `scopes` | install cli | detect scopes + upload | — |
| `scopes-git-refs` | install cli | get refs, store in meta-data | — |
| `scopes-upload` | install cli | read refs from meta-data, upload scopes | — |

### environment hook

Runs for all actions. Installs `mergify-cli`:

1. Install `uv` via `curl -LsSf https://astral.sh/uv/install.sh | sh` (if not on PATH)
2. Run `uv tool install mergify-cli`
3. Verify with `mergify --version`
4. If any step fails: exit 1 with clear error message

**Agent requirement:** Python 3.x must be available.

### command hook

Checks the `action` config:

- For `scopes`, `scopes-git-refs`, `scopes-upload`: runs the action logic (the plugin *is* the command)
- For `junit-process`: falls through by executing the user's original command via `bash -c "$BUILDKITE_COMMAND"`

### post-command hook

Checks the `action` config:

- For `junit-process`: runs the JUnit processing and upload
- For all other actions: no-op

## Action Implementations

### junit-process

Runs in `post-command` after the user's test command finishes.

1. Read `$BUILDKITE_COMMAND_EXIT_STATUS` (automatically available — no user config needed)
2. Map exit code: `0` -> `MERGIFY_TEST_EXIT_CODE=0`, non-zero -> `MERGIFY_TEST_EXIT_CODE=1`
3. Export environment variables:
   - `MERGIFY_API_URL` (from config, default `https://api.mergify.com`)
   - `MERGIFY_TOKEN` (from config)
   - `MERGIFY_JOB_NAME` (from config, default `$BUILDKITE_LABEL`)
   - `MERGIFY_TEST_EXIT_CODE` (from step 2)
4. Run: `mergify ci junit-process ${REPORT_PATH}`

The plugin does **not** change the step's exit code. If tests failed, the step still fails. The upload is best-effort: errors are logged but don't fail the build.

### scopes

Runs in `command` hook.

1. Export `MERGIFY_CONFIG_PATH` (from config, optional)
2. Run: `mergify ci scopes --write /tmp/mergify-scopes.json`
3. Parse outputs (base, head, scopes) from mergify cli stdout
4. Store via `buildkite-agent meta-data set`:
   - `mergify-ci.scopes` = scopes JSON
   - `mergify-ci.base` = base SHA
   - `mergify-ci.head` = head SHA
5. If token is set:
   - Export `MERGIFY_TOKEN`, `MERGIFY_API_URL`, `MERGIFY_CONFIG_PATH`
   - Run: `mergify ci scopes-send --file /tmp/mergify-scopes.json`
6. If token is not set:
   - Log warning: "Mergify token is not set, scopes will not be sent to Mergify API"

### scopes-git-refs

Runs in `command` hook.

1. Export `MERGIFY_CONFIG_PATH` (from config, optional)
2. Run: `mergify ci git-refs`
3. Parse base/head from cli output
4. Store via `buildkite-agent meta-data set`:
   - `mergify-ci.base` = base SHA
   - `mergify-ci.head` = head SHA

### scopes-upload

Runs in `command` hook.

1. Read refs from meta-data: `buildkite-agent meta-data get "mergify-ci.base"` / `"mergify-ci.head"`
2. Convert comma-separated `scopes` config to JSON array
3. Build scopes JSON file with `base_ref`, `head_ref`, `scopes` fields
4. If token is set:
   - Export `MERGIFY_TOKEN`, `MERGIFY_API_URL`, `MERGIFY_CONFIG_PATH`
   - Run: `mergify ci scopes-send --file /tmp/mergify-scopes.json`
5. If token is not set:
   - Log warning

## Cross-step Communication

All meta-data keys are namespaced under `mergify-ci.`:

| Key | Set by | Read by | Value |
|-----|--------|---------|-------|
| `mergify-ci.base` | `scopes`, `scopes-git-refs` | `scopes-upload` | Base SHA string |
| `mergify-ci.head` | `scopes`, `scopes-git-refs` | `scopes-upload` | Head SHA string |
| `mergify-ci.scopes` | `scopes` | user steps | JSON string of scopes |

## Error Handling

| Scenario | Behavior |
|----------|----------|
| `mergify-cli` not found after install | Fail with error pointing to Python/uv requirements |
| API upload failure in `junit-process` | Log error, **don't fail the step** (test results are the priority) |
| API upload failure in scope actions | Fail the step (upload is the step's only purpose) |
| Missing required config (e.g., no `action`) | Fail early with message listing what's missing |
| Invalid `action` value | Fail with list of valid actions |
| Missing token for scope upload | Log warning, don't fail |

## Testing Strategy

### BATS Unit Tests

Test each action's logic in isolation:

- Mock `buildkite-agent` commands (meta-data set/get)
- Mock `mergify` CLI (stub that validates args and returns fixture data)
- Mock Buildkite environment variables (`BUILDKITE_COMMAND_EXIT_STATUS`, `BUILDKITE_LABEL`, etc.)
- Test cases per action: happy path, missing config, missing token warning, CLI failure handling

### Buildkite Integration Pipeline

`.buildkite/pipeline.yml` runs end-to-end tests:

- Start mock API server (same `mockserver/mockserver:5.15.0` image as GHA action)
- Run `junit-process` against fixture JUnit XML
- Run `scopes-git-refs` -> `scopes-upload` flow
- Run `scopes` detection
- Verify meta-data values are set correctly
