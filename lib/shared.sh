#!/bin/bash
set -euo pipefail

# Read a plugin configuration property.
# Uses the BUILDKITE_PLUGIN_MERGIFY_CI_ prefix convention.
#
# printf, never echo: bash's builtin echo eats a lone -n/-e/-E/-ne as flags, so
# a config value that happens to be one of them comes back as the empty string
# and the caller silently behaves as if the property were unset.
plugin_config() {
  local key="BUILDKITE_PLUGIN_MERGIFY_CI_${1}"
  printf '%s\n' "${!key:-${2:-}}"
}

# Read a required plugin configuration property. Exits 1 if missing.
plugin_config_required() {
  local value
  value="$(plugin_config "$1")"
  if [[ -z "$value" ]]; then
    echo "~~~ :warning: Missing required config: ${1,,}" >&2
    echo "See plugin documentation for usage." >&2
    exit 1
  fi
  printf '%s\n' "$value"
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

# Resolve the Mergify token from plugin config or environment.
resolve_token() {
  local token
  token="$(plugin_config TOKEN "${MERGIFY_TOKEN:-}")"
  printf '%s\n' "$token"
}
