#!/usr/bin/env bats

setup() {
  load helpers/stub
  stub_buildkite_agent
  export BUILDKITE="true"
  export BUILDKITE_PULL_REQUEST="42"
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

@test "scopes-upload: reads CSV scopes from plugin config" {
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

@test "scopes-upload: reads JSON scopes from meta-data" {
  mkdir -p "${BATS_TEST_TMPDIR}/metadata"
  echo "abc123" > "${BATS_TEST_TMPDIR}/metadata/mergify-ci.base"
  echo "def456" > "${BATS_TEST_TMPDIR}/metadata/mergify-ci.head"
  echo '{"backend": "true", "frontend": "false"}' > "${BATS_TEST_TMPDIR}/metadata/mergify-ci.scopes"

  stub_mergify_scopes "abc123" "def456" '{}'
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="scopes-upload"
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN="test-token"

  run bash hooks/command

  [ "$status" -eq 0 ]
  # Verify only "true" scopes are included
  [[ "$output" == *'"backend"'* ]]
}

@test "scopes-upload: fails when no scopes in config or meta-data" {
  mkdir -p "${BATS_TEST_TMPDIR}/metadata"
  echo "abc123" > "${BATS_TEST_TMPDIR}/metadata/mergify-ci.base"
  echo "def456" > "${BATS_TEST_TMPDIR}/metadata/mergify-ci.head"

  stub_mergify_scopes "abc123" "def456" '{}'
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="scopes-upload"
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN="test-token"

  run bash hooks/command

  [ "$status" -ne 0 ]
  [[ "$output" == *"No scopes found"* ]]
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
