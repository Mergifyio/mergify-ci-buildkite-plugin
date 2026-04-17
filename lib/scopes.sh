#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shared.sh
source "${DIR}/shared.sh"

# Capture mergify-cli outputs via the GITHUB_OUTPUT mechanism.
# Creates a temp file and prints its path. The caller must export GITHUB_OUTPUT
# to that path before invoking mergify, since this function runs in a subshell
# when called via $() and cannot export into the parent shell.
setup_output_capture() {
  mktemp
}

# Parse a simple key=value from the captured output file.
# Returns empty string if the key is not found.
parse_output() {
  local file="$1"
  local key="$2"
  grep "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- || true
}

run_scopes_git_refs() {
  log_info "Detecting git refs..."

  local config_path
  config_path="$(plugin_config MERGIFY_CONFIG_PATH "")"
  if [[ -n "$config_path" ]]; then
    export MERGIFY_CONFIG_PATH="$config_path"
  fi

  local outfile
  outfile="$(setup_output_capture)"
  export GITHUB_OUTPUT="$outfile"

  mergify ci git-refs

  local base head
  base="$(parse_output "$outfile" "base")"
  head="$(parse_output "$outfile" "head")"
  rm -f "$outfile"

  if [[ -z "$base" || -z "$head" ]]; then
    log_error "Failed to detect git refs"
    exit 1
  fi

  echo "Base: $base"
  echo "Head: $head"

  buildkite-agent meta-data set "mergify-ci.base" "$base"
  buildkite-agent meta-data set "mergify-ci.head" "$head"
}

run_scopes() {
  log_info "Detecting scopes..."

  local config_path
  config_path="$(plugin_config MERGIFY_CONFIG_PATH "")"
  if [[ -n "$config_path" ]]; then
    export MERGIFY_CONFIG_PATH="$config_path"
  fi

  local scopes_file="/tmp/mergify-scopes.json"
  local outfile
  outfile="$(setup_output_capture)"
  export GITHUB_OUTPUT="$outfile"

  mergify ci scopes --write "$scopes_file"

  # Extract base/head from captured outputs
  local base head
  base="$(parse_output "$outfile" "base")"
  head="$(parse_output "$outfile" "head")"

  # Extract scopes — this is a multiline value delimited by ghadelimiter_<uuid>
  # Format: scopes<<ghadelimiter_<uuid>\n<json>\nghadelimiter_<uuid>
  local scopes_json
  scopes_json="$(sed -n '/^scopes<</,/^ghadelimiter_/{/^scopes<</d;/^ghadelimiter_/d;p}' "$outfile")"
  rm -f "$outfile"

  if [[ -n "$base" ]]; then
    buildkite-agent meta-data set "mergify-ci.base" "$base"
  fi
  if [[ -n "$head" ]]; then
    buildkite-agent meta-data set "mergify-ci.head" "$head"
  fi
  if [[ -n "$scopes_json" ]]; then
    buildkite-agent meta-data set "mergify-ci.scopes" "$scopes_json"

    # Annotate the build with detected scopes
    local annotation
    annotation="<details><summary>:mergify: Mergify CI — Detected scopes</summary><ul>"
    local scope enabled
    while IFS= read -r scope; do
      enabled=$(echo "$scopes_json" | jq -r --arg s "$scope" '.[$s]')
      if [[ "$enabled" == "true" ]]; then
        annotation+="<li>:white_check_mark: ${scope}</li>"
      else
        annotation+="<li>:no_entry_sign: ${scope}</li>"
      fi
    done < <(echo "$scopes_json" | jq -r 'keys[]')
    annotation+="</ul></details>"
    buildkite-agent annotate "$annotation" --style "info" --context "mergify-ci-scopes"
  fi

  # Upload to Mergify API only in pull request context
  if [[ "${BUILDKITE_PULL_REQUEST:-false}" == "false" ]]; then
    log_info "Not a pull request build, skipping scopes upload to Mergify API."
  else
    local token
    token="$(resolve_token)"
    if [[ -n "$token" ]]; then
      export MERGIFY_TOKEN="$token"
      export MERGIFY_API_URL
      MERGIFY_API_URL="$(plugin_config MERGIFY_API_URL "https://api.mergify.com")"
      mergify ci scopes-send --file "$scopes_file"
    else
      log_warning "Mergify token is not set, scopes will not be sent to Mergify API"
    fi
  fi
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
