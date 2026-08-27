#!/usr/bin/env bats

setup() {
  load helpers/stub
  # Install into a throwaway dir so the hook never touches the real ~/.local/bin.
  export MERGIFY_INSTALL_DIR="${BATS_TEST_TMPDIR}/bin"
  # Stub curl so the hook downloads a fake install.sh instead of hitting GitHub.
  stub_curl_install
}

@test "environment: installs the pinned default when version is unset" {
  run bash hooks/environment

  [ "$status" -eq 0 ]
  # Read the default straight from the hook so this stays green when Renovate
  # bumps DEFAULT_MERGIFY_CLI_VERSION.
  default="$(grep -oE 'DEFAULT_MERGIFY_CLI_VERSION="[^"]+"' hooks/environment | cut -d'"' -f2)"
  grep -q -- "raw.githubusercontent.com/Mergifyio/mergify-cli/${default}/install.sh$" "${BATS_TEST_TMPDIR}/curl.log"
  [[ "$output" == *"installed MERGIFY_VERSION=${default}"* ]]
}

@test "environment: installs latest from main when version is 'latest'" {
  export BUILDKITE_PLUGIN_MERGIFY_CI_MERGIFY_CLI_VERSION="latest"

  run bash hooks/environment

  [ "$status" -eq 0 ]
  grep -q -- "raw.githubusercontent.com/Mergifyio/mergify-cli/main/install.sh$" "${BATS_TEST_TMPDIR}/curl.log"
  [[ "$output" == *"installed MERGIFY_VERSION=latest"* ]]
}

@test "environment: pins install.sh and version to the requested release" {
  export BUILDKITE_PLUGIN_MERGIFY_CI_MERGIFY_CLI_VERSION="2026.6.15.1"

  run bash hooks/environment

  [ "$status" -eq 0 ]
  grep -q -- "raw.githubusercontent.com/Mergifyio/mergify-cli/2026.6.15.1/install.sh$" "${BATS_TEST_TMPDIR}/curl.log"
  [[ "$output" == *"installed MERGIFY_VERSION=2026.6.15.1"* ]]
}

@test "environment: fails when the binary is not installed" {
  # curl that downloads an installer doing nothing — no mergify binary appears.
  cat > "${BATS_TEST_TMPDIR}/stubs/curl" <<'STUB'
#!/bin/bash
echo ':'
STUB
  chmod +x "${BATS_TEST_TMPDIR}/stubs/curl"

  # Minimal PATH so a real mergify on the dev machine can't mask the failure.
  PATH="${BATS_TEST_TMPDIR}/stubs:/usr/bin:/bin" run bash hooks/environment

  [ "$status" -ne 0 ]
  [[ "$output" == *"mergify-cli installation failed"* ]]
}

@test "environment: warns that a token from plugin config is stored with the pipeline" {
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN="mock-token"

  run bash hooks/environment

  [ "$status" -eq 0 ]
  [[ "$output" == *"Plugin config 'token' is set"* ]]
}

@test "environment: stays quiet when the token comes from the environment" {
  export MERGIFY_TOKEN="env-token"

  run bash hooks/environment

  [ "$status" -eq 0 ]
  [[ "$output" != *"Plugin config 'token'"* ]]
}

@test "environment: warns on an action that never resolves a token" {
  # scopes-git-refs uses no token, and a non-PR build skips the upload path
  # entirely, so resolve_token is never reached. The value is in the stored
  # pipeline all the same, so the warning belongs in this per-job hook.
  export BUILDKITE_PLUGIN_MERGIFY_CI_ACTION="scopes-git-refs"
  export BUILDKITE_PULL_REQUEST="false"
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN="mock-token"

  run bash hooks/environment

  [ "$status" -eq 0 ]
  [[ "$output" == *"Plugin config 'token' is set"* ]]
}

@test "environment: never fails the job over a token, which would skip checkout and the command" {
  # A failed environment hook makes the agent skip the checkout and command
  # phases, so rejecting a token here would take down the user's test suite
  # over how its token was delivered. Rejection happens where the token is
  # actually used instead.
  export BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN='$MERGIFY_TOKEN'

  run bash hooks/environment

  [ "$status" -eq 0 ]
}
