#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shared.sh
source "${DIR}/shared.sh"

# Succeeds when the step declares that the pull request impacts every scope.
all_scopes_requested() {
  local all_scopes
  plugin_config all_scopes ALL_SCOPES "false"
  [[ "$all_scopes" == "true" ]]
}

# Succeeds when the installed mergify-cli has `ci git-refs --for-scopes`, which
# 2026.11.20 added: an older one refuses the flag. Only an option line counts,
# as the help's description mentions the flag too.
git_refs_has_for_scopes() {
  local help
  help="$(mergify ci git-refs --help)" || return 1
  grep -qE -- '^[[:space:]]*(-[[:alnum:]], )?--for-scopes([[:space:]]|$)' <<<"$help"
}

# Make a directory of the job's own for the files the step hands the CLI, into
# the variable named <var>, removed when the hook's shell exits however it
# exits. It goes under TMPDIR, or under /tmp, where the step's files went
# before, when TMPDIR is unset, empty or not a directory: mktemp names it, so
# no other job on the agent's host writes to it even there. Once per hook: the
# trap replaces the one a previous call set.
make_work_dir() {
  local __tmp="${TMPDIR:-}" __dir
  if [[ ! -d "$__tmp" ]]; then
    __tmp=/tmp
  fi
  __dir="$(mktemp -d "${__tmp}/mergify-ci.XXXXXX")"
  # The path is expanded now, as <var> may be a local gone by then. errexit
  # still holds in the trap: `|| true` keeps a failed cleanup from failing a
  # step that did its work.
  # shellcheck disable=SC2064
  trap "rm -rf -- $(printf '%q' "$__dir") || true" EXIT
  printf -v "$1" '%s' "$__dir"
}

run_scopes_git_refs() {
  log_info "Detecting git refs..."

  local config_path
  plugin_config config_path MERGIFY_CONFIG_PATH ""
  if [[ -n "$config_path" ]]; then
    export MERGIFY_CONFIG_PATH="$config_path"
  fi

  # On a merge queue batch built on other batches, mergify-cli 2026.11.20 and
  # later give the base branch commit below all of them as the base, so a diff
  # also holds the pull requests of those batches. --for-scopes keeps the top of
  # those batches, the base the batch's scopes are detected from and the only
  # one an older CLI gives.
  if git_refs_has_for_scopes; then
    mergify ci git-refs --for-scopes
  else
    mergify ci git-refs
  fi
}

run_scopes() {
  log_info "Detecting scopes..."

  local config_path
  plugin_config config_path MERGIFY_CONFIG_PATH ""
  if [[ -n "$config_path" ]]; then
    export MERGIFY_CONFIG_PATH="$config_path"
  fi

  local work_dir
  make_work_dir work_dir
  local scopes_file="${work_dir}/scopes.json"
  mergify ci scopes --write "$scopes_file"

  # Upload to Mergify API only in pull request context
  if [[ "${BUILDKITE_PULL_REQUEST:-false}" == "false" ]]; then
    log_info "Not a pull request build, skipping scopes upload to Mergify API."
    return 0
  fi

  local token
  resolve_token token
  if [[ -z "$token" ]]; then
    log_warning "Mergify token is not set, scopes will not be sent to Mergify API"
    return 0
  fi

  local args=(--scopes-json "$scopes_file")

  # A report replaces the previous one for the same commit, so the extra
  # scopes go in the detection's report rather than in one of their own. The
  # CLI trims each line and skips the empty ones.
  local extra_scopes
  plugin_config extra_scopes SCOPES ""
  if [[ -n "$extra_scopes" ]]; then
    local extra_scopes_file="${work_dir}/extra-scopes.txt"
    printf '%s\n' "$extra_scopes" | tr ',' '\n' > "$extra_scopes_file"
    args+=(--scopes-file "$extra_scopes_file")
  fi

  if all_scopes_requested; then
    args+=(--all)
  fi

  export MERGIFY_TOKEN="$token"
  export MERGIFY_API_URL
  resolve_api_url MERGIFY_API_URL
  mergify ci scopes-send "${args[@]}"
}

run_scopes_upload() {
  if [[ "${BUILDKITE_PULL_REQUEST:-false}" == "false" ]]; then
    log_info "Not a pull request build, skipping scopes upload."
    return 0
  fi

  log_info "Uploading scopes..."

  local config_path
  plugin_config config_path MERGIFY_CONFIG_PATH ""
  if [[ -n "$config_path" ]]; then
    export MERGIFY_CONFIG_PATH="$config_path"
  fi

  # Read refs from meta-data, set by a scopes-git-refs step this one depends
  # on. `--default ''` turns a missing key into the error below, which
  # names that step. Any other failure still stops the hook on the agent's
  # own message, which is then the actual cause.
  local base head
  base="$(buildkite-agent meta-data get --default '' "mergify-ci.base")"
  head="$(buildkite-agent meta-data get --default '' "mergify-ci.head")"
  if [[ -z "$base" || -z "$head" ]]; then
    log_error "No git refs found in meta-data: run a 'scopes-git-refs' step first and add its key to this step's 'depends_on'"
    log_detail "'scopes-upload' reads mergify-ci.base and mergify-ci.head, which a 'scopes-git-refs' step sets."
    exit 1
  fi

  # Read scopes from plugin config or meta-data
  local scopes_raw scopes_json
  plugin_config scopes_raw SCOPES ""
  if [[ -z "$scopes_raw" ]]; then
    scopes_raw="$(buildkite-agent meta-data get "mergify-ci.scopes" 2>/dev/null || true)"
  fi

  # Support both JSON ({"backend":"true",...}) and CSV (backend,frontend) formats
  if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$scopes_raw"; then
    # JSON object: extract keys where value is "true"
    scopes_json=$(jq '[to_entries[] | select(.value == "true") | .key]' <<<"$scopes_raw")
  else
    # CSV: one name per comma or line, each trimmed and the blank ones
    # dropped, the way `ci scopes-send` reads the extra scopes the `scopes`
    # step hands it.
    scopes_json=$(printf '%s\n' "$scopes_raw" | tr ',' '\n' |
      jq -R -s 'split("\n") | map(sub("^\\s+"; "") | sub("\\s+$"; "") | select(length > 0))')

    # A pull request that impacts every scope may carry no concrete one.
    if [[ "$scopes_json" == "[]" ]] && ! all_scopes_requested; then
      log_error "No scopes found: set 'scopes' in plugin config or run a 'scopes' step first"
      exit 1
    fi
  fi

  # Build scopes file
  local work_dir
  make_work_dir work_dir
  local scopes_file="${work_dir}/scopes.json"
  jq -n \
    --arg base "$base" \
    --arg head "$head" \
    --argjson scopes "$scopes_json" \
    '{base_ref: $base, head_ref: $head, scopes: $scopes}' > "$scopes_file"

  echo "Created scopes file:"
  cat "$scopes_file"

  # Upload to Mergify API if token is set
  local token
  resolve_token token
  if [[ -z "$token" ]]; then
    log_warning "Mergify token is not set, scopes will not be sent to Mergify API"
  else
    local args=(--scopes-json "$scopes_file")
    if all_scopes_requested; then
      args+=(--all)
    fi
    export MERGIFY_TOKEN="$token"
    export MERGIFY_API_URL
    resolve_api_url MERGIFY_API_URL
    mergify ci scopes-send "${args[@]}"
  fi
}
