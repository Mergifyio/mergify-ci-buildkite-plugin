#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shared.sh
source "${DIR}/shared.sh"

run_scopes_git_refs() {
  log_info "Detecting git refs..."

  local config_path
  config_path="$(plugin_config MERGIFY_CONFIG_PATH "")"
  if [[ -n "$config_path" ]]; then
    export MERGIFY_CONFIG_PATH="$config_path"
  fi

  mergify ci git-refs
}

run_scopes() {
  log_info "Detecting scopes..."

  local config_path
  config_path="$(plugin_config MERGIFY_CONFIG_PATH "")"
  if [[ -n "$config_path" ]]; then
    export MERGIFY_CONFIG_PATH="$config_path"
  fi

  local scopes_file="/tmp/mergify-scopes.json"
  mergify ci scopes --write "$scopes_file"

  # Upload to Mergify API only in pull request context
  if [[ "${BUILDKITE_PULL_REQUEST:-false}" == "false" ]]; then
    log_info "Not a pull request build, skipping scopes upload to Mergify API."
    return 0
  fi

  local token
  token="$(resolve_token)"
  if [[ -z "$token" ]]; then
    log_warning "Mergify token is not set, scopes will not be sent to Mergify API"
    return 0
  fi

  export MERGIFY_TOKEN="$token"
  export MERGIFY_API_URL
  MERGIFY_API_URL="$(plugin_config MERGIFY_API_URL "https://api.mergify.com")"
  mergify ci scopes-send --file "$scopes_file"
}

run_scopes_upload() {
  if [[ "${BUILDKITE_PULL_REQUEST:-false}" == "false" ]]; then
    log_info "Not a pull request build, skipping scopes upload."
    return 0
  fi

  log_info "Uploading scopes..."

  local config_path
  config_path="$(plugin_config MERGIFY_CONFIG_PATH "")"
  if [[ -n "$config_path" ]]; then
    export MERGIFY_CONFIG_PATH="$config_path"
  fi

  # Read refs from meta-data (set by a previous scopes-git-refs step)
  local base head
  base="$(buildkite-agent meta-data get "mergify-ci.base")"
  head="$(buildkite-agent meta-data get "mergify-ci.head")"

  # Read scopes from plugin config or meta-data
  local scopes_raw scopes_json
  scopes_raw="$(plugin_config SCOPES "")"
  if [[ -z "$scopes_raw" ]]; then
    scopes_raw="$(buildkite-agent meta-data get "mergify-ci.scopes" 2>/dev/null || true)"
  fi

  if [[ -z "$scopes_raw" ]]; then
    log_error "No scopes found: set 'scopes' in plugin config or run a 'scopes' step first"
    exit 1
  fi

  # Support both JSON ({"backend":"true",...}) and CSV (backend,frontend) formats
  if echo "$scopes_raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    # JSON object: extract keys where value is "true"
    scopes_json=$(echo "$scopes_raw" | jq '[to_entries[] | select(.value == "true") | .key]')
  else
    # CSV: split into JSON array
    scopes_json=$(echo "$scopes_raw" | jq -R -s 'rtrimstr("\n") | split(",")')
  fi

  # Build scopes file
  local scopes_file="/tmp/mergify-scopes.json"
  jq -n \
    --arg base "$base" \
    --arg head "$head" \
    --argjson scopes "$scopes_json" \
    '{base_ref: $base, head_ref: $head, scopes: $scopes}' > "$scopes_file"

  echo "Created scopes file:"
  cat "$scopes_file"

  # Upload to Mergify API if token is set
  local token
  token="$(plugin_config TOKEN "")"
  if [[ -n "$token" ]]; then
    export MERGIFY_TOKEN="$token"
    export MERGIFY_API_URL
    MERGIFY_API_URL="$(plugin_config MERGIFY_API_URL "https://api.mergify.com")"
    mergify ci scopes-send --file "$scopes_file"
  else
    log_warning "Mergify token is not set, scopes will not be sent to Mergify API"
  fi
}
