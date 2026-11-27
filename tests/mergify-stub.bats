#!/usr/bin/env bats

# The `mergify` stubs are the only CLI this suite ever runs, so they are what
# stands between a flag rename and a green build. These pin that they refuse
# what the real CLI refuses, or hides on its way to refusing: a stub that
# drifts back to matching on the subcommand alone passes every other test.

setup() {
  load helpers/stub
  stub_buildkite_agent
}

@test "stub: scopes-send rejects the deprecated --file alias" {
  stub_mergify_scopes "abc123" "def456" '{}'
  echo '{"scopes": ["backend"]}' > "${BATS_TEST_TMPDIR}/scopes.json"

  run mergify ci scopes-send --file "${BATS_TEST_TMPDIR}/scopes.json"

  [ "$status" -eq 2 ]
  [[ "$output" == *"unexpected argument '--file'"* ]]
}

@test "stub: scopes-send accepts --scopes-json and logs its content" {
  stub_mergify_scopes "abc123" "def456" '{}'
  echo '{"scopes": ["backend"], "base_ref": "abc123"}' > "${BATS_TEST_TMPDIR}/scopes.json"

  run mergify ci scopes-send --scopes-json "${BATS_TEST_TMPDIR}/scopes.json"

  [ "$status" -eq 0 ]
  grep -Fx -- 'scopes-json={"scopes":["backend"],"base_ref":"abc123"}' "${BATS_TEST_TMPDIR}/mergify.log"
}

@test "stub: scopes-send rejects a scopes JSON the CLI cannot load" {
  stub_mergify_scopes "abc123" "def456" '{}'
  echo '{"scopes": "backend"}' > "${BATS_TEST_TMPDIR}/scopes.json"

  run mergify ci scopes-send --scopes-json "${BATS_TEST_TMPDIR}/scopes.json"

  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot parse scopes JSON"* ]]
}

@test "stub: an option missing its value is refused" {
  stub_mergify_scopes "abc123" "def456" '{}'

  run mergify ci scopes --write

  [ "$status" -eq 2 ]
  [[ "$output" == *"a value is required for '--write'"* ]]
}

@test "stub: git-refs before 2026.11.20 refuses --for-scopes and does not list it" {
  stub_mergify_git_refs "abc123" "def456"

  run mergify ci git-refs --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--format"* ]]
  [[ "$output" != *"--for-scopes"* ]]

  run mergify ci git-refs --for-scopes
  [ "$status" -eq 2 ]
  [[ "$output" == *"unexpected argument '--for-scopes'"* ]]
}

@test "stub: git-refs from 2026.11.20 lists --for-scopes and gives the scopes base with it" {
  stub_mergify_git_refs "queue0base" "def456" "abc123"

  run mergify ci git-refs --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--for-scopes"* ]]

  run mergify ci git-refs
  [ "$status" -eq 0 ]
  [[ "$output" == *"Base: queue0base"* ]]

  run mergify ci git-refs --for-scopes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Base: abc123"* ]]
}

@test "stub: git-refs refuses a positional argument" {
  stub_mergify_git_refs "abc123" "def456"

  run mergify ci git-refs extra

  [ "$status" -eq 2 ]
}

@test "stub: junit-process refuses an unknown option before --" {
  stub_mergify_junit 0

  run mergify ci junit-process --report "reports/*.xml"

  [ "$status" -eq 2 ]
  [ ! -f "${BATS_TEST_TMPDIR}/mergify.log" ]
}

@test "stub: junit-process requires a report path" {
  stub_mergify_junit 0

  run mergify ci junit-process --

  [ "$status" -eq 2 ]
}

@test "stub: a single-valued option passed twice is refused" {
  stub_mergify_scopes "abc123" "def456" '{}'

  run mergify ci scopes-send --scopes-json a.json --scopes-json b.json

  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot be used multiple times"* ]]
}
