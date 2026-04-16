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
