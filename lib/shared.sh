#!/bin/bash
set -euo pipefail

# Read a plugin configuration property.
# Uses the BUILDKITE_PLUGIN_MERGIFY_ prefix convention.
plugin_config() {
  local key="BUILDKITE_PLUGIN_MERGIFY_${1}"
  echo "${!key:-${2:-}}"
}

# Read a required plugin configuration property. Exits 1 if missing.
plugin_config_required() {
  local key="BUILDKITE_PLUGIN_MERGIFY_${1}"
  local value="${!key:-}"
  if [[ -z "$value" ]]; then
    echo "~~~ :warning: Missing required config: ${1,,}" >&2
    echo "See plugin documentation for usage." >&2
    exit 1
  fi
  echo "$value"
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
