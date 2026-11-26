#!/bin/bash
set -euo pipefail

# Read a plugin configuration property into the variable named <var>:
#
#   plugin_config <var> <KEY> [default]
#
# Uses the BUILDKITE_PLUGIN_MERGIFY_CI_ prefix convention.
#
# It exits on a configured value that is an unexpanded variable reference, so
# it assigns by name instead of printing for `$(...)`: an exit there only
# leaves the subshell, and the caller then stops only if errexit sees the
# status, which it does not for `local x="$(...)"`, inside `[[ ]]`, or in a
# function called as a condition. The hook would go on with an empty value.
# Called directly, the exit ends the hook wherever it is called from. The `__`
# locals keep it from shadowing a caller's <var>, which assign_trimmed would
# then assign instead. The other readers below follow the same shape.
plugin_config() {
  local __key="BUILDKITE_PLUGIN_MERGIFY_CI_${2}"
  local __value="${!__key:-}"

  # `report_path: "$$REPORTS"` survives upload as the literal `$REPORTS`, and
  # Buildkite expands nothing in plugin config when the job runs. The literal
  # then fails far from here, as a pattern matching no file or a URL nothing
  # answers, and that failure never names the property. Only the configured
  # value is checked: a fallback comes from the caller.
  if is_unexpanded_reference "$__value"; then
    local __name
    __name="$(config_property_name "$2")"
    # Never echo the value back, for the reason given in resolve_token.
    log_error "Plugin config '${__name}' is an unexpanded variable reference."
    log_detail "It starts with '\$', so a variable name was passed through instead of its value. Buildkite does not expand '\$\$NAME' in plugin config when the job runs."
    log_detail "Set '${__name}' to the value itself, or to '\${NAME}' with a single '\$' to have it interpolated when the pipeline is uploaded."
    exit 1
  fi

  assign_trimmed "$1" "${__value:-${3:-}}"
}

# Assign <value> to the variable named <var>, without the trailing newlines
# `$(...)` would have dropped: a secret or a value read from a file usually
# ends with one, and a token sent with it is not the token.
assign_trimmed() {
  local __trimmed="$2"
  while [[ "$__trimmed" == *$'\n' ]]; do
    __trimmed="${__trimmed%$'\n'}"
  done
  printf -v "$1" '%s' "$__trimmed"
}

# Read a required plugin configuration property into <var>, like plugin_config.
# Exits 1 if it is missing or blank: `report_path: " "` passes an emptiness
# test and then splits into no report path at all.
plugin_config_required() {
  plugin_config "$1" "$2"
  local __value="${!1}"
  if [[ -z "${__value//[[:space:]]/}" ]]; then
    log_error "Missing required config: $(config_property_name "$2")"
    log_detail "See plugin documentation for usage."
    exit 1
  fi
}

# The property name as pipeline.yml spells it. `tr`, not `${1,,}`: that is
# bash 4, and macOS agents run the hooks with the system bash, 3.2.
config_property_name() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

# Succeeds when the value is an interpolation that did not happen: it starts
# with `$`. Leading whitespace and a wrapping quote are tolerated so a stray
# character cannot walk the value past the check.
is_unexpanded_reference() {
  local unexpanded='^[[:space:]]*["'"'"']?[$]'
  [[ "$1" =~ $unexpanded ]]
}

log_info() {
  echo "~~~ :mergify: $*"
}

log_warning() {
  echo "~~~ :warning: $*" >&2
}

# `+++`, not `~~~`: Buildkite renders a `~~~` group collapsed and greyed out,
# which would fold away the one line saying why the job just failed.
log_error() {
  echo "+++ :x: $*" >&2
}

# Follow-up line for a multi-line diagnostic. Unprefixed on purpose: the `~~~`
# or `+++` the other helpers emit is what opens a Buildkite log group, so
# repeating it would start a new group per line instead of filling the one just
# opened.
log_detail() {
  printf '%s\n' "$*" >&2
}

# Warn about a Mergify token supplied through plugin config. Called once per job
# from hooks/environment, so it covers every step carrying a `token:` whether or
# not that step goes on to resolve one: the value sits in the stored pipeline
# either way. It only warns, never fails: failing the environment hook makes the
# agent skip the checkout and command phases too, which would take down a test
# suite over how its token was delivered.
#
# Unconditional because nothing here can separate a baked-in secret from a
# deliberate mock one. `buildkite-agent pipeline upload` interpolates
# `token: "${MERGIFY_TOKEN}"` into the stored pipeline before the build starts,
# so by now both are just a string. Matching the shape of a real Mergify key
# instead would go quiet the day that format changes.
warn_token_config() {
  [[ -n "${BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN:-}" ]] || return 0

  log_warning "Plugin config 'token' is set. Plugin config is stored with the pipeline, rendered in the Buildkite UI and kept in build history."
  log_detail "Only pass a value that is not a secret. For a real token, remove 'token' and export MERGIFY_TOKEN in the agent environment. See the README Authentication section."
}

# Resolve the Mergify token into <var>, from plugin config or environment.
# Plugin config wins.
#
# The token is read here rather than through plugin_config, whose hint for an
# unexpanded value is to interpolate it at upload: for a token that bakes the
# secret into the stored pipeline. The check below covers both sources instead,
# with the token's own remedy.
resolve_token() {
  local __token="${BUILDKITE_PLUGIN_MERGIFY_CI_TOKEN:-${MERGIFY_TOKEN:-}}"

  # An interpolation that did not happen is never a token, whichever source it
  # came from: `token: "$$MERGIFY_TOKEN"` survives upload as the literal
  # `$MERGIFY_TOKEN`, and an `env:` block carrying the same literal reaches us
  # through MERGIFY_TOKEN instead. Either way it is non-empty, so it wins over
  # the fallback that would have worked and is sent as the token; the API
  # answers 401 without saying why.
  if is_unexpanded_reference "$__token"; then
    # Never echo the value back: a `$`-leading string can still be a real
    # secret (bcrypt and argon2 hashes both start with `$`), and this log is
    # kept in build history forever.
    log_error "The Mergify token is an unexpanded variable reference, not a token."
    log_detail "It starts with '\$', so a variable name was passed through instead of its value. Buildkite does not expand '\$\$NAME' in plugin config, and an env: block does not expand it either."
    log_detail "Export MERGIFY_TOKEN with the token's own value in the agent environment. See the README Authentication section."
    exit 1
  fi

  assign_trimmed "$1" "$__token"
}

# Resolve the Mergify API URL into <var>, from plugin config or environment.
# Plugin config wins, same as resolve_token. The environment fallback must not
# be dropped: callers export the result as MERGIFY_API_URL, so falling back to
# the SaaS default here would overwrite an on-prem URL exported next to
# MERGIFY_TOKEN and send that token to api.mergify.com.
resolve_api_url() {
  plugin_config "$1" MERGIFY_API_URL "${MERGIFY_API_URL:-https://api.mergify.com}"
}
