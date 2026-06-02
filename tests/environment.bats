#!/usr/bin/env bats

setup() {
  load helpers/stub
  # Stub uv (records its args) and mergify (so the post-install check passes).
  stub_command uv 0
  stub_command mergify 0 "mergify-cli 0.0.0-stub"
}

@test "environment: installs the pinned default when version is unset" {
  run bash hooks/environment

  [ "$status" -eq 0 ]
  # Read the default straight from the hook so this stays green when Renovate
  # bumps DEFAULT_MERGIFY_CLI_VERSION.
  default="$(grep -oE 'DEFAULT_MERGIFY_CLI_VERSION="[^"]+"' hooks/environment | cut -d'"' -f2)"
  grep -q -- "tool install --force --upgrade --python 3.13 mergify-cli==${default}$" "${BATS_TEST_TMPDIR}/uv.log"
}

@test "environment: installs latest when version is 'latest'" {
  export BUILDKITE_PLUGIN_MERGIFY_CI_MERGIFY_CLI_VERSION="latest"

  run bash hooks/environment

  [ "$status" -eq 0 ]
  grep -q -- "tool install --force --upgrade --python 3.13 mergify-cli$" "${BATS_TEST_TMPDIR}/uv.log"
}

@test "environment: pins the exact version when one is given" {
  export BUILDKITE_PLUGIN_MERGIFY_CI_MERGIFY_CLI_VERSION="2026.5.5.4"

  run bash hooks/environment

  [ "$status" -eq 0 ]
  grep -q -- "tool install --force --upgrade --python 3.13 mergify-cli==2026.5.5.4$" "${BATS_TEST_TMPDIR}/uv.log"
}

@test "environment: omits --python when python_version is 'system'" {
  export BUILDKITE_PLUGIN_MERGIFY_CI_PYTHON_VERSION="system"
  export BUILDKITE_PLUGIN_MERGIFY_CI_MERGIFY_CLI_VERSION="2026.5.5.4"

  run bash hooks/environment

  [ "$status" -eq 0 ]
  grep -q -- "tool install --force --upgrade mergify-cli==2026.5.5.4$" "${BATS_TEST_TMPDIR}/uv.log"
}
