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
    log_error "Missing required config: ${1,,}"
    log_detail "See plugin documentation for usage."
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

# Follow-up line for a multi-line diagnostic. Unprefixed on purpose: the `~~~`
# the other helpers emit is what opens a Buildkite log group, so repeating it
# would start a new group per line instead of filling the one just opened.
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
  [[ -n "$(plugin_config TOKEN)" ]] || return 0

  log_warning "Plugin config 'token' is set. Plugin config is stored with the pipeline, rendered in the Buildkite UI and kept in build history."
  log_detail "Only pass a value that is not a secret. For a real token, remove 'token' and export MERGIFY_TOKEN in the agent environment. See the README Authentication section."
}

# Resolve the Mergify token from plugin config or environment. Plugin config
# wins.
#
# This exits on a value that cannot be a token, so callers write
# `token="$(resolve_token)" || exit 1`. errexit already covers that today, but
# only because every caller splits the `local` from the assignment; the one-line
# `local token=$(resolve_token)` form returns `local`'s own status instead, and
# the caller would read the resulting empty string as "no token configured".
# The explicit `|| exit 1` does not depend on which form is used.
resolve_token() {
  local token
  token="$(plugin_config TOKEN "${MERGIFY_TOKEN:-}")"

  # An interpolation that did not happen is never a token, whichever source it
  # came from: `token: "$$MERGIFY_TOKEN"` survives upload as the literal
  # `$MERGIFY_TOKEN`, and an `env:` block carrying the same literal reaches us
  # through MERGIFY_TOKEN instead. Either way it is non-empty, so it wins over
  # the fallback that would have worked and is sent as the token; the API
  # answers 401 without saying why. Leading whitespace and a wrapping quote are
  # tolerated so a stray character cannot walk the value past the check.
  local unexpanded='^[[:space:]]*["'"'"']?[$]'
  if [[ "$token" =~ $unexpanded ]]; then
    # Never echo the value back: a `$`-leading string can still be a real
    # secret (bcrypt and argon2 hashes both start with `$`), and this log is
    # kept in build history forever.
    log_error "The Mergify token is an unexpanded variable reference, not a token."
    log_detail "It starts with '\$', so a variable name was passed through instead of its value. Buildkite does not expand '\$\$NAME' in plugin config, and an env: block does not expand it either."
    log_detail "Export MERGIFY_TOKEN with the token's own value in the agent environment. See the README Authentication section."
    exit 1
  fi

  printf '%s\n' "$token"
}
