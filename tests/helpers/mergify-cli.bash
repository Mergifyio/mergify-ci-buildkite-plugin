#!/bin/bash

# The mergify-cli argv contract the `mergify` stubs enforce, transcribed from
# the clap definitions in Mergifyio/mergify-cli (crates/mergify-cli/src/main.rs:
# GitRefsCliArgs, ScopesCliArgs, ScopesSendCliArgs, JunitProcessCliArgs, as of
# mergify-cli e7c1ebb).
#
# A stub that matches on the subcommand alone passes whatever flag the plugin
# hands it, so a flag the CLI renames or drops ships green. Only VISIBLE flags
# are listed: a hidden one is on its way out. `scopes-send --file` is the case
# that proves it — the real CLI still accepts it as the deprecated alias of
# `--scopes-json`, the plugin used it for every upload, and nothing here noticed.
#
# This cannot see the CLI change by itself. When the CLI renames a flag, this
# table is what has to follow, and every call site still using the old name
# then goes red.

# Prints "value <name>" or "flag <name>" for an option <subcommand> accepts,
# <name> being the long spelling without dashes. Fails for anything else.
_mergify_cli_option() {
  case "$1 $2" in
    "git-refs --format") printf 'value format\n' ;;

    "scopes --config") printf 'value config\n' ;;
    "scopes --base") printf 'value base\n' ;;
    "scopes --head") printf 'value head\n' ;;
    "scopes --write" | "scopes -w") printf 'value write\n' ;;

    "scopes-send --repository" | "scopes-send -r") printf 'value repository\n' ;;
    "scopes-send --pull-request" | "scopes-send -p") printf 'value pull-request\n' ;;
    "scopes-send --token" | "scopes-send -t") printf 'value token\n' ;;
    "scopes-send --api-url" | "scopes-send -u") printf 'value api-url\n' ;;
    "scopes-send --scope" | "scopes-send -s") printf 'value scope\n' ;;
    "scopes-send --scopes-json") printf 'value scopes-json\n' ;;
    "scopes-send --scopes-file") printf 'value scopes-file\n' ;;
    "scopes-send --head-sha") printf 'value head-sha\n' ;;
    "scopes-send --all") printf 'flag all\n' ;;

    "junit-process --api-url" | "junit-process -u") printf 'value api-url\n' ;;
    "junit-process --token" | "junit-process -t") printf 'value token\n' ;;
    "junit-process --repository" | "junit-process -r") printf 'value repository\n' ;;
    "junit-process --test-framework") printf 'value test-framework\n' ;;
    "junit-process --test-language") printf 'value test-language\n' ;;
    "junit-process --tests-target-branch" | "junit-process -b") printf 'value tests-target-branch\n' ;;
    "junit-process --test-exit-code" | "junit-process -e") printf 'value test-exit-code\n' ;;

    *) return 1 ;;
  esac
}

# Usage: mergify_cli_parse <subcommand> [args...]
# Prints one `<name>=<value>` line per option (`<name>=` for a boolean flag)
# and one `file=<value>` line per positional. On an argv the CLI would refuse,
# prints clap's wording to stderr and returns 2, clap's usage-error status.
mergify_cli_parse() {
  local subcommand="$1"
  shift

  local arg spec name value options_done=false positionals=0 seen=" "
  while [[ $# -gt 0 ]]; do
    arg="$1"
    shift
    if [[ "$options_done" == false && "$arg" == "--" ]]; then
      options_done=true
      continue
    fi
    if [[ "$options_done" == false && "$arg" == -?* ]]; then
      value=""
      local has_inline_value=false
      if [[ "$arg" == --*=* ]]; then
        value="${arg#*=}"
        arg="${arg%%=*}"
        has_inline_value=true
      fi
      if ! spec="$(_mergify_cli_option "$subcommand" "$arg")"; then
        printf "error: unexpected argument '%s' found\n" "$arg" >&2
        return 2
      fi
      name="${spec#* }"
      # clap 4 refuses a repeated option unless it collects into a Vec, which
      # among these only `scopes-send --scope` does.
      if [[ "$seen" == *" ${name} "* && "$name" != "scope" ]]; then
        printf "error: the argument '%s' cannot be used multiple times\n" "$arg" >&2
        return 2
      fi
      seen+="${name} "
      if [[ "$spec" == flag* ]]; then
        if [[ "$has_inline_value" == true ]]; then
          printf "error: unexpected value '%s' for '%s' found\n" "$value" "$arg" >&2
          return 2
        fi
        printf '%s=\n' "$name"
        continue
      fi
      if [[ "$has_inline_value" == false ]]; then
        if [[ $# -eq 0 ]]; then
          printf "error: a value is required for '%s' but none was supplied\n" "$arg" >&2
          return 2
        fi
        value="$1"
        shift
      fi
      printf '%s=%s\n' "$name" "$value"
      continue
    fi
    if [[ "$subcommand" != "junit-process" ]]; then
      printf "error: unexpected argument '%s' found\n" "$arg" >&2
      return 2
    fi
    printf 'file=%s\n' "$arg"
    positionals=$((positionals + 1))
  done

  if [[ "$subcommand" == "junit-process" && "$positionals" -eq 0 ]]; then
    printf 'error: the following required arguments were not provided:\n  <FILE>...\n' >&2
    return 2
  fi
}

# Usage: mergify_cli_value <parsed> <name>
# Prints the value parsed for <name> (the last one for a repeatable option),
# and fails when it was never passed.
mergify_cli_value() {
  local line found=false value=""
  while IFS= read -r line; do
    if [[ "$line" == "$2="* ]]; then
      value="${line#*=}"
      found=true
    fi
  done <<<"$1"
  [[ "$found" == true ]] && printf '%s\n' "$value"
}

# Usage: mergify_cli_check_scopes_json <path>
# Fails the way `ci scopes-send` does when the file is not the
# `{"scopes": [...], "all_scopes"?: bool}` shape its loader deserializes. Extra
# keys are accepted: the CLI's serde struct does not deny unknown fields.
mergify_cli_check_scopes_json() {
  if ! jq -e '
      type == "object"
      and (.scopes | type == "array" and all(type == "string"))
      and ((.all_scopes // false) | type == "boolean")
    ' "$1" >/dev/null 2>&1; then
    printf 'cannot parse scopes JSON from %s\n' "$1" >&2
    return 1
  fi
}
