# Buildkite Mergify CI Plugin — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Buildkite plugin that wraps `mergify-cli` to provide JUnit test report processing and scope detection/uploading for Mergify CI Insights and Merge Queue.

**Architecture:** Three hook scripts (`environment`, `command`, `post-command`) dispatch to action-specific functions in a `lib/` directory. The `environment` hook installs `mergify-cli` via `uv`. The `command` hook handles scope actions and falls through for `junit-process`. The `post-command` hook handles JUnit upload. Cross-step data passes via `buildkite-agent meta-data`.

**Tech Stack:** Bash (hooks/lib), BATS (tests), `mergify-cli` (Python, installed via `uv`), Buildkite Agent API (meta-data)

---

## File Structure

| File | Responsibility |
|------|---------------|
| `plugin.yml` | Plugin metadata and configuration schema |
| `hooks/environment` | Install `uv` and `mergify-cli` |
| `hooks/command` | Dispatch scope actions; fall through for junit-process |
| `hooks/post-command` | Run junit-process after user's test command |
| `lib/shared.sh` | Config reader, logging helpers |
| `lib/junit.sh` | junit-process logic |
| `lib/scopes.sh` | scopes, scopes-git-refs, scopes-upload logic |
| `tests/helpers/stub.bash` | BATS test stubs for buildkite-agent and mergify CLI |
| `tests/environment.bats` | Tests for environment hook |
| `tests/junit-process.bats` | Tests for junit-process action |
| `tests/scopes.bats` | Tests for scope actions |

---

### Task 1: Plugin Skeleton — plugin.yml and shared lib

**Files:**
- Create: `plugin.yml`
- Create: `lib/shared.sh`

- [ ] **Step 1: Create `plugin.yml`**

```yaml
name: Mergify CI
description: Mergify CI integration for Buildkite — JUnit processing, scope detection, and scope upload
author: https://github.com/mergify
requirements:
  - curl
  - bash
  - jq
configuration:
  properties:
    action:
      type: string
      enum:
        - junit-process
        - scopes
        - scopes-git-refs
        - scopes-upload
    token:
      type: string
    report_path:
      type: string
    scopes:
      type: string
    mergify_api_url:
      type: string
    job_name:
      type: string
    mergify_config_path:
      type: string
  required:
    - action
  additionalProperties: false
```

- [ ] **Step 2: Create `lib/shared.sh`**

```bash
#!/bin/bash
set -euo pipefail

# Read a plugin configuration property.
# Uses the BUILDKITE_PLUGIN_MERGIFY_CI_ prefix convention.
plugin_config() {
  local key="BUILDKITE_PLUGIN_MERGIFY_CI_${1}"
  echo "${!key:-${2:-}}"
}

# Read a required plugin configuration property. Exits 1 if missing.
plugin_config_required() {
  local key="BUILDKITE_PLUGIN_MERGIFY_CI_${1}"
  local value="${!key:-}"
  if [[ -z "$value" ]]; then
    echo "~~~ :warning: Missing required config: ${1,,}" >&2
    echo "See plugin documentation for usage." >&2
    exit 1
  fi
  echo "$value"
}

log_info() {
  echo "~~~ :mergify: $*"
}

log_warning() {
  echo "~~~ :warning: $*" >&2
}

log_error() {
  echo "~~~ :x: $*" >&2
}
```

- [ ] **Step 3: Verify file structure**

Run: `ls -la plugin.yml lib/shared.sh`
Expected: Both files exist.

- [ ] **Step 4: Commit**

```bash
git add plugin.yml lib/shared.sh
git commit -m "feat: add plugin.yml and shared lib"
```

---

### Task 2: Environment Hook — Install mergify-cli

**Files:**
- Create: `hooks/environment`

- [ ] **Step 1: Create `hooks/environment`**

```bash
#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shared.sh
source "${DIR}/../lib/shared.sh"

log_info "Installing mergify-cli..."

# Install uv if not available
if ! command -v uv &>/dev/null; then
  echo "uv not found, installing..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

# Install mergify-cli
uv tool install mergify-cli

# Verify installation
if ! command -v mergify &>/dev/null; then
  log_error "mergify-cli installation failed. Ensure Python 3.x is available on the agent."
  exit 1
fi

mergify --version
```

- [ ] **Step 2: Make the hook executable**

Run: `chmod +x hooks/environment`

- [ ] **Step 3: Verify**

Run: `file hooks/environment && head -1 hooks/environment`
Expected: Shows it's a script with `#!/bin/bash` shebang.

- [ ] **Step 4: Commit**

```bash
git add hooks/environment
git commit -m "feat: add environment hook to install mergify-cli"
```

---

### Task 3: Shared Lib — scopes.sh

**Files:**
- Create: `lib/scopes.sh`

The `mergify-cli` writes outputs to the file pointed to by `$GITHUB_OUTPUT` (a GHA mechanism). We reuse this by setting `GITHUB_OUTPUT` to a temp file, letting the CLI write structured `key=value` pairs, then parsing that file. This avoids fragile stdout parsing.

- [ ] **Step 1: Create `lib/scopes.sh`**

```bash
#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shared.sh
source "${DIR}/shared.sh"

# Capture mergify-cli outputs via the GITHUB_OUTPUT mechanism.
# Sets GITHUB_OUTPUT to a temp file, runs the command, then parses key=value pairs.
# Returns the path to the output file.
setup_output_capture() {
  local outfile
  outfile="$(mktemp)"
  export GITHUB_OUTPUT="$outfile"
  echo "$outfile"
}

# Parse a simple key=value from the captured output file.
parse_output() {
  local file="$1"
  local key="$2"
  grep "^${key}=" "$file" | head -1 | cut -d= -f2-
}

run_scopes_git_refs() {
  log_info "Detecting git refs..."

  local config_path
  config_path="$(plugin_config MERGIFY_CONFIG_PATH "")"
  if [[ -n "$config_path" ]]; then
    export MERGIFY_CONFIG_PATH="$config_path"
  fi

  local outfile
  outfile="$(setup_output_capture)"

  mergify ci git-refs

  local base head
  base="$(parse_output "$outfile" "base")"
  head="$(parse_output "$outfile" "head")"
  rm -f "$outfile"

  if [[ -z "$base" || -z "$head" ]]; then
    log_error "Failed to detect git refs"
    exit 1
  fi

  echo "Base: $base"
  echo "Head: $head"

  buildkite-agent meta-data set "mergify-ci.base" "$base"
  buildkite-agent meta-data set "mergify-ci.head" "$head"
}

run_scopes() {
  log_info "Detecting scopes..."

  local config_path
  config_path="$(plugin_config MERGIFY_CONFIG_PATH "")"
  if [[ -n "$config_path" ]]; then
    export MERGIFY_CONFIG_PATH="$config_path"
  fi

  local scopes_file="/tmp/mergify-scopes.json"
  local outfile
  outfile="$(setup_output_capture)"

  mergify ci scopes --write "$scopes_file"

  # Extract base/head from captured outputs
  local base head
  base="$(parse_output "$outfile" "base")"
  head="$(parse_output "$outfile" "head")"

  # Extract scopes — this is a multiline value delimited by ghadelimiter_<uuid>
  # Format: scopes<<ghadelimiter_<uuid>\n<json>\nghadelimiter_<uuid>
  local scopes_json
  scopes_json="$(sed -n '/^scopes<</,/^ghadelimiter_/{/^scopes<</d;/^ghadelimiter_/d;p}' "$outfile")"
  rm -f "$outfile"

  if [[ -n "$base" ]]; then
    buildkite-agent meta-data set "mergify-ci.base" "$base"
  fi
  if [[ -n "$head" ]]; then
    buildkite-agent meta-data set "mergify-ci.head" "$head"
  fi
  if [[ -n "$scopes_json" ]]; then
    buildkite-agent meta-data set "mergify-ci.scopes" "$scopes_json"
  fi

  # Upload to Mergify API if token is set
  local token
  token="$(plugin_config TOKEN "")"
  if [[ -n "$token" ]]; then
    export MERGIFY_TOKEN="$token"
    export MERGIFY_API_URL
    MERGIFY_API_URL="$(plugin_config MERGIFY_API_URL "https://api.mergify.com")"
    mergify ci scopes-send --file "$scopes_file"
  else
    log_warning "Mergify token is not set, scopes will not be sent to Mergify API"
  fi
}

run_scopes_upload() {
  log_info "Uploading scopes..."

  local config_path
  config_path="$(plugin_config MERGIFY_CONFIG_PATH "")"
  if [[ -n "$config_path" ]]; then
    export MERGIFY_CONFIG_PATH="$config_path"
  fi

  # Read refs from meta-data (set by a previous scopes-git-refs step)
  local base head
  base="$(buildkite-agent meta-data get "mergify-ci.base")"
  head="$(buildkite-agent meta-data get "mergify-ci.head")"

  # Read scopes from config
  local scopes_csv
  scopes_csv="$(plugin_config_required SCOPES)"

  # Convert comma-separated scopes to JSON array
  local scopes_json
  scopes_json=$(echo "$scopes_csv" | jq -R -s 'rtrimstr("\n") | split(",")')

  # Build scopes file
  local scopes_file="/tmp/mergify-scopes.json"
  jq -n \
    --arg base "$base" \
    --arg head "$head" \
    --argjson scopes "$scopes_json" \
    '{base_ref: $base, head_ref: $head, scopes: $scopes}' > "$scopes_file"

  echo "Created scopes file:"
  cat "$scopes_file"

  # Upload to Mergify API if token is set
  local token
  token="$(plugin_config TOKEN "")"
  if [[ -n "$token" ]]; then
    export MERGIFY_TOKEN="$token"
    export MERGIFY_API_URL
    MERGIFY_API_URL="$(plugin_config MERGIFY_API_URL "https://api.mergify.com")"
    mergify ci scopes-send --file "$scopes_file"
  else
    log_warning "Mergify token is not set, scopes will not be sent to Mergify API"
  fi
}
```

- [ ] **Step 2: Verify**

Run: `bash -n lib/scopes.sh`
Expected: No syntax errors.

- [ ] **Step 3: Commit**

```bash
git add lib/scopes.sh
git commit -m "feat: add scopes lib with git-refs, scopes, and scopes-upload"
```

---

### Task 4: Shared Lib — junit.sh

**Files:**
- Create: `lib/junit.sh`

- [ ] **Step 1: Create `lib/junit.sh`**

```bash
#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shared.sh
source "${DIR}/shared.sh"

run_junit_process() {
  log_info "Processing JUnit reports..."

  local report_path
  report_path="$(plugin_config_required REPORT_PATH)"

  # Export Mergify environment
  export MERGIFY_API_URL
  MERGIFY_API_URL="$(plugin_config MERGIFY_API_URL "https://api.mergify.com")"

  local token
  token="$(plugin_config TOKEN "")"
  if [[ -n "$token" ]]; then
    export MERGIFY_TOKEN="$token"
  fi

  local job_name
  job_name="$(plugin_config JOB_NAME "${BUILDKITE_LABEL:-}")"
  if [[ -n "$job_name" ]]; then
    export MERGIFY_JOB_NAME="$job_name"
  fi

  # Map Buildkite command exit status to mergify test exit code
  local exit_status="${BUILDKITE_COMMAND_EXIT_STATUS:-}"
  if [[ -n "$exit_status" ]]; then
    if [[ "$exit_status" == "0" ]]; then
      export MERGIFY_TEST_EXIT_CODE="0"
    else
      export MERGIFY_TEST_EXIT_CODE="1"
    fi
  fi

  # Run junit-process — best effort, don't fail the build
  # shellcheck disable=SC2086
  if ! mergify ci junit-process ${report_path}; then
    log_warning "Failed to upload JUnit report to Mergify CI. This does not affect your build."
  fi
}
```

- [ ] **Step 2: Verify**

Run: `bash -n lib/junit.sh`
Expected: No syntax errors.

- [ ] **Step 3: Commit**

```bash
git add lib/junit.sh
git commit -m "feat: add junit lib for JUnit report processing"
```

---

### Task 5: Command Hook

**Files:**
- Create: `hooks/command`

- [ ] **Step 1: Create `hooks/command`**

```bash
#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shared.sh
source "${DIR}/../lib/shared.sh"

ACTION="$(plugin_config_required ACTION)"

case "$ACTION" in
  scopes)
    # shellcheck source=lib/scopes.sh
    source "${DIR}/../lib/scopes.sh"
    run_scopes
    ;;
  scopes-git-refs)
    # shellcheck source=lib/scopes.sh
    source "${DIR}/../lib/scopes.sh"
    run_scopes_git_refs
    ;;
  scopes-upload)
    # shellcheck source=lib/scopes.sh
    source "${DIR}/../lib/scopes.sh"
    run_scopes_upload
    ;;
  junit-process)
    # Fall through: execute the user's original command.
    # The plugin's post-command hook will handle JUnit processing.
    bash -c "$BUILDKITE_COMMAND"
    ;;
  *)
    log_error "Unsupported action: $ACTION"
    echo "Valid actions are: junit-process, scopes, scopes-git-refs, scopes-upload"
    exit 1
    ;;
esac
```

- [ ] **Step 2: Make the hook executable**

Run: `chmod +x hooks/command`

- [ ] **Step 3: Commit**

```bash
git add hooks/command
git commit -m "feat: add command hook dispatching scope actions"
```

---

### Task 6: Post-command Hook

**Files:**
- Create: `hooks/post-command`

- [ ] **Step 1: Create `hooks/post-command`**

```bash
#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shared.sh
source "${DIR}/../lib/shared.sh"

ACTION="$(plugin_config ACTION "")"

case "$ACTION" in
  junit-process)
    # shellcheck source=lib/junit.sh
    source "${DIR}/../lib/junit.sh"
    run_junit_process
    ;;
  *)
    # No-op for other actions
    ;;
esac
```

- [ ] **Step 2: Make the hook executable**

Run: `chmod +x hooks/post-command`

- [ ] **Step 3: Commit**

```bash
git add hooks/post-command
git commit -m "feat: add post-command hook for junit-process"
```

---

### Task 7: BATS Test Helpers

**Files:**
- Create: `tests/helpers/stub.bash`

- [ ] **Step 1: Create `tests/helpers/stub.bash`**

```bash
#!/bin/bash

# Create a stub command that records its invocations and returns a canned response.
# Usage: stub_command <name> <exit_code> [stdout_output]
stub_command() {
  local name="$1"
  local exit_code="$2"
  local output="${3:-}"
  local stub_dir="${BATS_TEST_TMPDIR}/stubs"
  local stub_log="${BATS_TEST_TMPDIR}/${name}.log"

  mkdir -p "$stub_dir"
  cat > "${stub_dir}/${name}" <<STUB
#!/bin/bash
echo "\$@" >> "${stub_log}"
if [[ -n "${output}" ]]; then
  echo "${output}"
fi
exit ${exit_code}
STUB
  chmod +x "${stub_dir}/${name}"
  export PATH="${stub_dir}:${PATH}"
}

# Create a buildkite-agent stub that handles meta-data set/get.
# Meta-data is stored in files under BATS_TEST_TMPDIR/metadata/.
stub_buildkite_agent() {
  local stub_dir="${BATS_TEST_TMPDIR}/stubs"
  local metadata_dir="${BATS_TEST_TMPDIR}/metadata"
  local log="${BATS_TEST_TMPDIR}/buildkite-agent.log"

  mkdir -p "$stub_dir" "$metadata_dir"
  cat > "${stub_dir}/buildkite-agent" <<'STUB'
#!/bin/bash
METADATA_DIR="__METADATA_DIR__"
LOG="__LOG__"
echo "$@" >> "$LOG"
if [[ "$1" == "meta-data" && "$2" == "set" ]]; then
  echo "$4" > "${METADATA_DIR}/$3"
elif [[ "$1" == "meta-data" && "$2" == "get" ]]; then
  cat "${METADATA_DIR}/$3" 2>/dev/null
fi
STUB
  sed -i '' "s|__METADATA_DIR__|${metadata_dir}|g" "${stub_dir}/buildkite-agent"
  sed -i '' "s|__LOG__|${log}|g" "${stub_dir}/buildkite-agent"
  chmod +x "${stub_dir}/buildkite-agent"
  export PATH="${stub_dir}:${PATH}"
}

# Create a mergify stub that writes to GITHUB_OUTPUT like the real CLI.
stub_mergify_git_refs() {
  local base="$1"
  local head="$2"
  local stub_dir="${BATS_TEST_TMPDIR}/stubs"

  mkdir -p "$stub_dir"
  cat > "${stub_dir}/mergify" <<STUB
#!/bin/bash
if [[ "\$1" == "ci" && "\$2" == "git-refs" ]]; then
  echo "Base: ${base}"
  echo "Head: ${head}"
  if [[ -n "\${GITHUB_OUTPUT:-}" ]]; then
    echo "base=${base}" >> "\$GITHUB_OUTPUT"
    echo "head=${head}" >> "\$GITHUB_OUTPUT"
  fi
  exit 0
elif [[ "\$1" == "--version" ]]; then
  echo "mergify-cli 0.0.0-stub"
  exit 0
fi
echo "Unexpected args: \$@" >&2
exit 1
STUB
  chmod +x "${stub_dir}/mergify"
  export PATH="${stub_dir}:${PATH}"
}

# Create a mergify stub for scopes action.
stub_mergify_scopes() {
  local base="$1"
  local head="$2"
  local scopes_json="$3"  # e.g. '{"backend": "true", "frontend": "false"}'
  local stub_dir="${BATS_TEST_TMPDIR}/stubs"

  mkdir -p "$stub_dir"
  cat > "${stub_dir}/mergify" <<STUB
#!/bin/bash
if [[ "\$1" == "ci" && "\$2" == "scopes" ]]; then
  # Parse --write flag
  WRITE_FILE=""
  shift 2
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      --write) WRITE_FILE="\$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  echo "Base: ${base}"
  echo "Head: ${head}"
  if [[ -n "\${GITHUB_OUTPUT:-}" ]]; then
    echo "base=${base}" >> "\$GITHUB_OUTPUT"
    echo "head=${head}" >> "\$GITHUB_OUTPUT"
    local delimiter="ghadelimiter_test"
    echo "scopes<<\${delimiter}" >> "\$GITHUB_OUTPUT"
    echo '${scopes_json}' >> "\$GITHUB_OUTPUT"
    echo "\${delimiter}" >> "\$GITHUB_OUTPUT"
  fi
  if [[ -n "\$WRITE_FILE" ]]; then
    echo '{"scopes": ["backend"]}' > "\$WRITE_FILE"
  fi
  exit 0
elif [[ "\$1" == "ci" && "\$2" == "scopes-send" ]]; then
  echo "Scopes sent successfully"
  exit 0
elif [[ "\$1" == "--version" ]]; then
  echo "mergify-cli 0.0.0-stub"
  exit 0
fi
echo "Unexpected args: \$@" >&2
exit 1
STUB
  chmod +x "${stub_dir}/mergify"
  export PATH="${stub_dir}:${PATH}"
}

# Create a mergify stub for junit-process action.
stub_mergify_junit() {
  local exit_code="${1:-0}"
  local stub_dir="${BATS_TEST_TMPDIR}/stubs"
  local log="${BATS_TEST_TMPDIR}/mergify.log"

  mkdir -p "$stub_dir"
  cat > "${stub_dir}/mergify" <<STUB
#!/bin/bash
if [[ "\$1" == "ci" && "\$2" == "junit-process" ]]; then
  shift 2
  echo "junit-process \$@" >> "${log}"
  echo "MERGIFY_TOKEN=\${MERGIFY_TOKEN:-}" >> "${log}"
  echo "MERGIFY_API_URL=\${MERGIFY_API_URL:-}" >> "${log}"
  echo "MERGIFY_JOB_NAME=\${MERGIFY_JOB_NAME:-}" >> "${log}"
  echo "MERGIFY_TEST_EXIT_CODE=\${MERGIFY_TEST_EXIT_CODE:-}" >> "${log}"
  exit ${exit_code}
elif [[ "\$1" == "--version" ]]; then
  echo "mergify-cli 0.0.0-stub"
  exit 0
fi
echo "Unexpected args: \$@" >&2
exit 1
STUB
  chmod +x "${stub_dir}/mergify"
  export PATH="${stub_dir}:${PATH}"
}
```

- [ ] **Step 2: Commit**

```bash
git add tests/helpers/stub.bash
git commit -m "feat: add BATS test helpers with CLI and agent stubs"
```

---

### Task 8: BATS Tests — junit-process

**Files:**
- Create: `tests/junit-process.bats`

- [ ] **Step 1: Create `tests/junit-process.bats`**

```bash
#!/usr/bin/env bats

setup() {
  load helpers/stub
  export BUILDKITE_LABEL="test-job"
  export BUILDKITE_COMMAND_EXIT_STATUS="0"
}

@test "junit-process: uploads report with correct env vars" {
  stub_mergify_junit 0
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  export BUILDKITE_PLUGIN_MERGIFY_CI_REPORT_PATH="reports/*.xml"
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN="test-token"

  run bash hooks/post-command

  [ "$status" -eq 0 ]
  # Verify mergify was called with the report path
  grep "junit-process reports/\*.xml" "${BATS_TEST_TMPDIR}/mergify.log"
  # Verify env vars were passed
  grep "MERGIFY_TOKEN=test-token" "${BATS_TEST_TMPDIR}/mergify.log"
  grep "MERGIFY_API_URL=https://api.mergify.com" "${BATS_TEST_TMPDIR}/mergify.log"
  grep "MERGIFY_JOB_NAME=test-job" "${BATS_TEST_TMPDIR}/mergify.log"
  grep "MERGIFY_TEST_EXIT_CODE=0" "${BATS_TEST_TMPDIR}/mergify.log"
}

@test "junit-process: maps non-zero exit status to exit code 1" {
  stub_mergify_junit 0
  export BUILDKITE_COMMAND_EXIT_STATUS="2"
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  export BUILDKITE_PLUGIN_MERGIFY_CI_REPORT_PATH="reports/*.xml"
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN="test-token"

  run bash hooks/post-command

  [ "$status" -eq 0 ]
  grep "MERGIFY_TEST_EXIT_CODE=1" "${BATS_TEST_TMPDIR}/mergify.log"
}

@test "junit-process: uses custom job_name when provided" {
  stub_mergify_junit 0
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  export BUILDKITE_PLUGIN_MERGIFY_CI_REPORT_PATH="reports/*.xml"
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN="test-token"
  export BUILDKITE_PLUGIN_MERGIFY_CI_JOB_NAME="custom-name"

  run bash hooks/post-command

  [ "$status" -eq 0 ]
  grep "MERGIFY_JOB_NAME=custom-name" "${BATS_TEST_TMPDIR}/mergify.log"
}

@test "junit-process: does not fail build when upload fails" {
  stub_mergify_junit 1
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  export BUILDKITE_PLUGIN_MERGIFY_CI_REPORT_PATH="reports/*.xml"
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN="test-token"

  run bash hooks/post-command

  [ "$status" -eq 0 ]
}

@test "junit-process: fails when report_path is missing" {
  stub_mergify_junit 0
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN="test-token"

  run bash hooks/post-command

  [ "$status" -ne 0 ]
}

@test "post-command: no-op for scopes action" {
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="scopes"

  run bash hooks/post-command

  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run tests**

Run: `cd /Users/sileht/workspace/mergify/buildkite-mergify-ci && bats tests/junit-process.bats`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add tests/junit-process.bats
git commit -m "test: add BATS tests for junit-process action"
```

---

### Task 9: BATS Tests — scopes actions

**Files:**
- Create: `tests/scopes.bats`

- [ ] **Step 1: Create `tests/scopes.bats`**

```bash
#!/usr/bin/env bats

setup() {
  load helpers/stub
  stub_buildkite_agent
}

@test "scopes-git-refs: stores base and head in meta-data" {
  stub_mergify_git_refs "abc123" "def456"
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="scopes-git-refs"

  run bash hooks/command

  [ "$status" -eq 0 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/metadata/mergify-ci.base")" = "abc123" ]
  [ "$(cat "${BATS_TEST_TMPDIR}/metadata/mergify-ci.head")" = "def456" ]
}

@test "scopes: detects scopes and stores in meta-data" {
  stub_mergify_scopes "abc123" "def456" '{"backend": "true", "frontend": "false"}'
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="scopes"

  run bash hooks/command

  [ "$status" -eq 0 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/metadata/mergify-ci.base")" = "abc123" ]
  [ "$(cat "${BATS_TEST_TMPDIR}/metadata/mergify-ci.head")" = "def456" ]
  [ "$(cat "${BATS_TEST_TMPDIR}/metadata/mergify-ci.scopes")" = '{"backend": "true", "frontend": "false"}' ]
}

@test "scopes: uploads when token is set" {
  stub_mergify_scopes "abc123" "def456" '{"backend": "true"}'
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="scopes"
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN="test-token"

  run bash hooks/command

  [ "$status" -eq 0 ]
  grep "scopes-send" "${BATS_TEST_TMPDIR}/buildkite-agent.log" || true
}

@test "scopes: warns when token is not set" {
  stub_mergify_scopes "abc123" "def456" '{"backend": "true"}'
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="scopes"

  run bash hooks/command

  [ "$status" -eq 0 ]
  [[ "$output" == *"Mergify token is not set"* ]]
}

@test "scopes-upload: reads meta-data and uploads" {
  # Pre-set meta-data as if scopes-git-refs ran first
  mkdir -p "${BATS_TEST_TMPDIR}/metadata"
  echo "abc123" > "${BATS_TEST_TMPDIR}/metadata/mergify-ci.base"
  echo "def456" > "${BATS_TEST_TMPDIR}/metadata/mergify-ci.head"

  stub_mergify_scopes "abc123" "def456" '{}'
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="scopes-upload"
  export BUILDKITE_PLUGIN_MERGIFY_CI_SCOPES="backend,frontend"
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN="test-token"

  run bash hooks/command

  [ "$status" -eq 0 ]
}

@test "scopes-upload: fails when scopes config is missing" {
  mkdir -p "${BATS_TEST_TMPDIR}/metadata"
  echo "abc123" > "${BATS_TEST_TMPDIR}/metadata/mergify-ci.base"
  echo "def456" > "${BATS_TEST_TMPDIR}/metadata/mergify-ci.head"

  stub_buildkite_agent
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="scopes-upload"
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN="test-token"

  run bash hooks/command

  [ "$status" -ne 0 ]
}

@test "command: falls through to user command for junit-process" {
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  export BUILDKITE_COMMAND="echo hello-from-user-command"

  run bash hooks/command

  [ "$status" -eq 0 ]
  [[ "$output" == *"hello-from-user-command"* ]]
}

@test "command: fails for invalid action" {
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="invalid-action"

  run bash hooks/command

  [ "$status" -ne 0 ]
  [[ "$output" == *"Unsupported action"* ]]
}
```

- [ ] **Step 2: Run tests**

Run: `cd /Users/sileht/workspace/mergify/buildkite-mergify-ci && bats tests/scopes.bats`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add tests/scopes.bats
git commit -m "test: add BATS tests for scope actions"
```

---

### Task 10: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Create `README.md`**

```markdown
# Mergify CI Buildkite Plugin

A Buildkite plugin for integrating with [Mergify CI Insights](https://mergify.com) — upload JUnit test reports, detect pull request scopes, and upload scopes to Mergify Merge Queue.

## Actions

### `junit-process`

Process JUnit XML test reports and upload them to Mergify CI Insights. Detects silent test failures automatically using the step's exit code.

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

### `scopes`

Detect which code scopes are affected by a pull request and upload them to the Mergify API.

```yaml
steps:
  - label: "Detect scopes"
    plugins:
      - mergify/mergify-ci#v1:
          action: scopes
          token: "${MERGIFY_CI_TOKEN}"
```

### `scopes-git-refs`

Return the merge-queue-aware base and head SHAs. Results are stored as Buildkite meta-data (`mergify-ci.base`, `mergify-ci.head`) for use by subsequent steps.

```yaml
steps:
  - label: "Get git refs"
    key: git-refs
    plugins:
      - mergify/mergify-ci#v1:
          action: scopes-git-refs
```

### `scopes-upload`

Upload pre-computed scopes to the Mergify API. Requires a prior `scopes-git-refs` step.

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

## Configuration

| Property | Required | Default | Description |
|----------|----------|---------|-------------|
| `action` | yes | — | `junit-process`, `scopes`, `scopes-git-refs`, or `scopes-upload` |
| `token` | for API calls | — | Mergify CI authentication token |
| `report_path` | for junit-process | — | Glob path to JUnit XML files |
| `scopes` | for scopes-upload | — | Comma-separated list of scopes |
| `mergify_api_url` | no | `https://api.mergify.com` | Mergify API endpoint |
| `job_name` | no | Step label | Override job name (useful for matrix builds) |
| `mergify_config_path` | no | — | Path to `.mergify.yml` configuration file |

## Meta-data

The plugin stores the following values via `buildkite-agent meta-data`:

| Key | Set by | Description |
|-----|--------|-------------|
| `mergify-ci.base` | `scopes`, `scopes-git-refs` | Merge-queue-aware base SHA |
| `mergify-ci.head` | `scopes`, `scopes-git-refs` | Merge-queue-aware head SHA |
| `mergify-ci.scopes` | `scopes` | JSON mapping of scope names to "true"/"false" |

## Requirements

- Python 3.x on the Buildkite agent
- `curl` (for installing `uv`)
- `jq` (for JSON processing in `scopes-upload`)

## Development

### Running tests

```bash
bats tests/
```

## License

MIT
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with usage examples and configuration reference"
```

---

### Task 11: Integration Test Pipeline

**Files:**
- Create: `.buildkite/pipeline.yml`
- Create: `zfixtures/junit_example.xml`

- [ ] **Step 1: Copy test fixture from GHA repo**

Run: `cp /Users/sileht/workspace/mergify/gha-mergify-ci/zfixtures/junit_example.xml zfixtures/junit_example.xml`

- [ ] **Step 2: Create `.buildkite/pipeline.yml`**

```yaml
steps:
  - label: ":bash: BATS unit tests"
    command: bats tests/
    plugins:
      - docker#v5.11.0:
          image: "bats/bats:latest"
          mount-checkout: true

  - label: ":junit: Test junit-process"
    command: "echo 'Test run complete'"
    plugins:
      - mergify/mergify-ci#${BUILDKITE_COMMIT}:
          action: junit-process
          report_path: "zfixtures/junit_example.xml"
          token: "${MERGIFY_CI_TOKEN}"
          mergify_api_url: "http://localhost:1080"

  - label: ":mag: Test scopes-git-refs"
    key: test-git-refs
    plugins:
      - mergify/mergify-ci#${BUILDKITE_COMMIT}:
          action: scopes-git-refs

  - label: ":upload: Test scopes-upload"
    depends_on: test-git-refs
    plugins:
      - mergify/mergify-ci#${BUILDKITE_COMMIT}:
          action: scopes-upload
          scopes: "backend,frontend"
          token: "${MERGIFY_CI_TOKEN}"
          mergify_api_url: "http://localhost:1080"

  - label: ":mag: Test scopes"
    plugins:
      - mergify/mergify-ci#${BUILDKITE_COMMIT}:
          action: scopes
          token: "${MERGIFY_CI_TOKEN}"
          mergify_api_url: "http://localhost:1080"
```

- [ ] **Step 3: Commit**

```bash
git add .buildkite/pipeline.yml zfixtures/junit_example.xml
git commit -m "ci: add Buildkite integration test pipeline and test fixtures"
```
