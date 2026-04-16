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
