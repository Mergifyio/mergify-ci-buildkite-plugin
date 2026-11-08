#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shared.sh
source "${DIR}/shared.sh"

# Succeeds when the step declares that the pull request impacts every scope.
all_scopes_requested() {
  [[ "$(plugin_config ALL_SCOPES "false")" == "true" ]]
}

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
  token="$(resolve_token)" || exit 1
  if [[ -z "$token" ]]; then
    log_warning "Mergify token is not set, scopes will not be sent to Mergify API"
    return 0
  fi

  local args=(--scopes-json "$scopes_file")

  # A report replaces the previous one for the same commit, so the extra
  # scopes go in the detection's report rather than in one of their own. The
  # CLI trims each line and skips the empty ones.
  local extra_scopes
  extra_scopes="$(plugin_config SCOPES "")"
  if [[ -n "$extra_scopes" ]]; then
    local extra_scopes_file="/tmp/mergify-extra-scopes.txt"
    printf '%s\n' "$extra_scopes" | tr ',' '\n' > "$extra_scopes_file"
    args+=(--scopes-file "$extra_scopes_file")
  fi

  if all_scopes_requested; then
    args+=(--all)
  fi

  export MERGIFY_TOKEN="$token"
  export MERGIFY_API_URL
  MERGIFY_API_URL="$(resolve_api_url)"
  mergify ci scopes-send "${args[@]}"
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

  # A pull request that impacts every scope may carry no concrete one.
  if [[ -z "$scopes_raw" ]] && ! all_scopes_requested; then
    log_error "No scopes found: set 'scopes' in plugin config or run a 'scopes' step first"
    exit 1
  fi

  # Support both JSON ({"backend":"true",...}) and CSV (backend,frontend) formats
  if [[ -z "$scopes_raw" ]]; then
    scopes_json="[]"
  elif jq -e 'type == "object"' >/dev/null 2>&1 <<<"$scopes_raw"; then
    # JSON object: extract keys where value is "true"
    scopes_json=$(jq '[to_entries[] | select(.value == "true") | .key]' <<<"$scopes_raw")
  else
    # CSV: split into JSON array
    scopes_json=$(jq -R -s 'rtrimstr("\n") | split(",")' <<<"$scopes_raw")
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
  token="$(resolve_token)" || exit 1
  if [[ -z "$token" ]]; then
    log_warning "Mergify token is not set, scopes will not be sent to Mergify API"
  else
    local args=(--scopes-json "$scopes_file")
    if all_scopes_requested; then
      args+=(--all)
    fi
    export MERGIFY_TOKEN="$token"
    export MERGIFY_API_URL
    MERGIFY_API_URL="$(resolve_api_url)"
    mergify ci scopes-send "${args[@]}"
  fi
}
