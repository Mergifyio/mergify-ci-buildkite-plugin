#!/usr/bin/env bats

setup() {
  load helpers/stub
  export BUILDKITE_LABEL="test-job"
  export BUILDKITE_COMMAND_EXIT_STATUS="0"
  unset MERGIFY_API_URL BUILDKITE_PLUGIN_MERGIFY_CI_MERGIFY_API_URL
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
  grep -Fx -- "MERGIFY_API_URL=https://api.mergify.com" "${BATS_TEST_TMPDIR}/mergify.log"
  grep "MERGIFY_TEST_JOB_NAME=test-job" "${BATS_TEST_TMPDIR}/mergify.log"
  grep "MERGIFY_TEST_EXIT_CODE=0" "${BATS_TEST_TMPDIR}/mergify.log"
}

@test "junit-process: falls back to MERGIFY_API_URL env var when mergify_api_url config is unset" {
  stub_mergify_junit 0
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  export BUILDKITE_PLUGIN_MERGIFY_CI_REPORT_PATH="reports/*.xml"
  export MERGIFY_TOKEN="env-token"
  export MERGIFY_API_URL="https://mergify.example.internal"

  run bash hooks/post-command

  [ "$status" -eq 0 ]
  grep -Fx -- "MERGIFY_API_URL=https://mergify.example.internal" "${BATS_TEST_TMPDIR}/mergify.log"
}

@test "junit-process: an empty MERGIFY_API_URL env var falls back to the SaaS default" {
  stub_mergify_junit 0
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  export BUILDKITE_PLUGIN_MERGIFY_CI_REPORT_PATH="reports/*.xml"
  export MERGIFY_TOKEN="env-token"
  export MERGIFY_API_URL=""

  run bash hooks/post-command

  [ "$status" -eq 0 ]
  grep -Fx -- "MERGIFY_API_URL=https://api.mergify.com" "${BATS_TEST_TMPDIR}/mergify.log"
}

@test "junit-process: mergify_api_url config wins over the MERGIFY_API_URL env var" {
  stub_mergify_junit 0
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  export BUILDKITE_PLUGIN_MERGIFY_CI_REPORT_PATH="reports/*.xml"
  export BUILDKITE_PLUGIN_MERGIFY_CI_MERGIFY_API_URL="https://from-config.example"
  export MERGIFY_TOKEN="env-token"
  export MERGIFY_API_URL="https://from-env.example"

  run bash hooks/post-command

  [ "$status" -eq 0 ]
  grep -Fx -- "MERGIFY_API_URL=https://from-config.example" "${BATS_TEST_TMPDIR}/mergify.log"
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
  # The message itself, not just the status: a bash 4 construct on this path
  # dies with "bad substitution" on bash 3.2, before printing it, and still
  # exits non-zero. `+++` opens the group, so the reason is not folded away.
  [[ "$output" == *"+++ :x: Missing required config: report_path"* ]]
  [ ! -f "${BATS_TEST_TMPDIR}/mergify.log" ]
}

@test "junit-process: fails when report_path is only whitespace" {
  stub_mergify_junit 0
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  export BUILDKITE_PLUGIN_MERGIFY_CI_REPORT_PATH=$' \t '
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN="test-token"

  run bash hooks/post-command

  # It splits into no path at all: `junit-process --` with nothing to upload
  # on bash 5, an unbound "${report_paths[@]}" on bash 3.2.
  [ "$status" -ne 0 ]
  [[ "$output" == *"Missing required config: report_path"* ]]
  [ ! -f "${BATS_TEST_TMPDIR}/mergify.log" ]
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
  # Not the hint every other property gets: `${MERGIFY_TOKEN}` interpolated
  # at upload would bake the secret into the stored pipeline.
  [[ "$output" == *"Export MERGIFY_TOKEN"* ]]
  [[ "$output" != *"interpolated when the pipeline is uploaded"* ]]
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

@test "junit-process: rejects any property that is an unexpanded variable" {
  stub_mergify_junit 0
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  export BUILDKITE_PLUGIN_MERGIFY_CI_REPORT_PATH="reports/*.xml"
  export MERGIFY_TOKEN="env-token"

  # What `<property>: "$$NAME"` reaches the plugin as. Each would otherwise
  # fail far from its cause: a pattern matching no file, a URL nothing
  # answers, a job name nobody chose.
  local property
  for property in report_path mergify_api_url job_name; do
    run env "BUILDKITE_PLUGIN_MERGIFY_CI_$(tr '[:lower:]' '[:upper:]' <<<"$property")=\$SOME_VAR" \
      bash hooks/post-command

    [ "$status" -ne 0 ]
    [[ "$output" == *"+++ :x: Plugin config '${property}' is an unexpanded variable reference"* ]]
  done
  [ ! -f "${BATS_TEST_TMPDIR}/mergify.log" ]
}

@test "junit-process: reads every line of report_path" {
  stub_mergify_junit 0
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  # A YAML block scalar: a blank first line used to split into no path at
  # all, and every line after the first was dropped.
  export BUILDKITE_PLUGIN_MERGIFY_CI_REPORT_PATH=$'\nreports/*.xml\nother/*.xml\n'
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN="test-token"

  run bash hooks/post-command

  [ "$status" -eq 0 ]
  grep -Fx -- "junit-process -- reports/*.xml other/*.xml" "${BATS_TEST_TMPDIR}/mergify.log"
}

@test "junit-process: sends a token without its trailing newline" {
  stub_mergify_junit 0
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="junit-process"
  export BUILDKITE_PLUGIN_MERGIFY_CI_REPORT_PATH="reports/*.xml"
  # What a secret read from a file usually looks like.
  export MERGIFY_TOKEN=$'env-token\n'

  run bash hooks/post-command

  [ "$status" -eq 0 ]
  grep -Fx -- "MERGIFY_TOKEN=env-token" "${BATS_TEST_TMPDIR}/mergify.log"
  # A token still ending in a newline would leave an empty line after it.
  run grep -cx -- "" "${BATS_TEST_TMPDIR}/mergify.log"
  [ "$output" = "0" ]
}
