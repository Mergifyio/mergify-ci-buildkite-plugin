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
  grep -Fx -- "junit-process -- reports/*.xml" "${BATS_TEST_TMPDIR}/mergify.log"
  # Verify env vars were passed
  grep "MERGIFY_TOKEN=test-token" "${BATS_TEST_TMPDIR}/mergify.log"
  grep "MERGIFY_API_URL=https://api.mergify.com" "${BATS_TEST_TMPDIR}/mergify.log"
  grep "MERGIFY_TEST_JOB_NAME=test-job" "${BATS_TEST_TMPDIR}/mergify.log"
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
  grep "MERGIFY_TEST_JOB_NAME=custom-name" "${BATS_TEST_TMPDIR}/mergify.log"
}

@test "junit-process: fails the step when CLI exits non-zero" {
  stub_mergify_junit 1
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  export BUILDKITE_PLUGIN_MERGIFY_CI_REPORT_PATH="reports/*.xml"
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN="test-token"

  run bash hooks/post-command

  # The plugin propagates the CLI exit code so quarantine failures fail the step.
  [ "$status" -ne 0 ]
  # No extra log on top of the CLI's own output.
  [[ "$output" != *"Failed to upload"* ]]
}

@test "junit-process: a glob match starting with a dash cannot become a CLI option" {
  stub_mergify_junit 0
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  export BUILDKITE_PLUGIN_MERGIFY_CI_REPORT_PATH="*.xml"
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN="test-token"

  # A file an untrusted build step (fork PR checkout, downloaded artifact)
  # could drop in the workspace. Let bash expand the glob and this name
  # lands in argv, where the CLI reads it as an option, not as a path.
  local workspace="${BATS_TEST_TMPDIR}/workspace"
  mkdir -p "$workspace"
  touch "${workspace}/--api-url=evil.example.com.xml"
  cd "$workspace"

  run bash "${BATS_TEST_DIRNAME}/../hooks/post-command"

  [ "$status" -eq 0 ]
  # The pattern reaches the CLI unexpanded, so the malicious name never
  # lands in argv, and `--` keeps it positional if it ever does.
  grep -Fx -- "junit-process -- *.xml" "${BATS_TEST_TMPDIR}/mergify.log"
  ! grep -F -- "--api-url=" "${BATS_TEST_TMPDIR}/mergify.log"
}

@test "junit-process: keeps space-separated report_path patterns" {
  stub_mergify_junit 0
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  export BUILDKITE_PLUGIN_MERGIFY_CI_REPORT_PATH="reports/*.xml other/*.xml"
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN="test-token"

  run bash hooks/post-command

  [ "$status" -eq 0 ]
  grep -Fx -- "junit-process -- reports/*.xml other/*.xml" "${BATS_TEST_TMPDIR}/mergify.log"
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

@test "junit-process: an option-shaped report_path is not eaten as a flag" {
  stub_mergify_junit 0
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  export BUILDKITE_PLUGIN_MERGIFY_CI_REPORT_PATH="-n"
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN="test-token"

  run bash hooks/post-command

  [ "$status" -eq 0 ]
  grep -Fx -- "junit-process -- -n" "${BATS_TEST_TMPDIR}/mergify.log"
}

@test "junit-process: an option-shaped token is not eaten as a flag" {
  stub_mergify_junit 0
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  export BUILDKITE_PLUGIN_MERGIFY_CI_REPORT_PATH="reports/*.xml"
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN="-n"

  run bash hooks/post-command

  [ "$status" -eq 0 ]
  grep -Fx -- "MERGIFY_TOKEN=-n" "${BATS_TEST_TMPDIR}/mergify.log"
}

@test "junit-process: rejects a token config that is an unexpanded variable" {
  stub_mergify_junit 0
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  export BUILDKITE_PLUGIN_MERGIFY_CI_REPORT_PATH="reports/*.xml"
  # What `token: "$$MERGIFY_TOKEN"` reaches the plugin as: the escape survives
  # upload, and plugin config wins, so the literal shadows the env var that
  # would have worked and is sent as the token.
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN='$MERGIFY_TOKEN'
  export MERGIFY_TOKEN="env-token"

  run bash hooks/post-command

  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpanded variable reference"* ]]
  [ ! -f "${BATS_TEST_TMPDIR}/mergify.log" ]
}

@test "junit-process: rejects an unexpanded variable arriving through the environment" {
  stub_mergify_junit 0
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  export BUILDKITE_PLUGIN_MERGIFY_CI_REPORT_PATH="reports/*.xml"
  # An env: block carrying the same literal is just as unusable as the plugin
  # config form, so the check is on the resolved token, not on its source.
  export MERGIFY_TOKEN='$SOME_OTHER_SECRET'

  run bash hooks/post-command

  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpanded variable reference"* ]]
}

@test "junit-process: rejects an unexpanded variable padded with space or quotes" {
  stub_mergify_junit 0
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  export BUILDKITE_PLUGIN_MERGIFY_CI_REPORT_PATH="reports/*.xml"
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN=' "$MERGIFY_TOKEN"'

  run bash hooks/post-command

  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpanded variable reference"* ]]
}

@test "junit-process: never echoes the rejected token value into the build log" {
  stub_mergify_junit 0
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  export BUILDKITE_PLUGIN_MERGIFY_CI_REPORT_PATH="reports/*.xml"
  # A `$`-leading value can still be a real secret: bcrypt and argon2 hashes
  # both start with `$`, and the build log is kept forever.
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN='$2b$12$notarealsecretbutshaped'

  run bash hooks/post-command

  [ "$status" -ne 0 ]
  [[ "$output" != *"notarealsecretbutshaped"* ]]
}
