#!/usr/bin/env bats

# Guard for a bug class that ships silently: bash's builtin `echo` eats a lone
# -n/-e/-E/-ne as flags, so `echo "$value"` turns those values into the empty
# string instead of failing. Nothing else catches it — shellcheck does not flag
# it, and it only shows up as a property that looks unset. Use
# `printf '%s\n' "$value"` to emit a value, and a here-string to feed one to
# stdin. Only a literal prefix makes `echo` safe, which is why the log_* helpers
# interpolate after their fixed `~~~ :x: ` and log_detail uses printf.
@test "lint: no value is emitted through echo" {
  cd "${BATS_TEST_DIRNAME}/.."

  run grep -rnE 'echo +-?-? *"?\$' lib hooks

  # grep exits 1 for "found nothing" and 2 for "could not look", so a bare
  # `-ne 0` would pass on a wrong working directory, silently guarding nothing.
  [ "$status" -eq 1 ] || {
    echo "grep exited ${status}; expected 1 (no matches)"
    echo "use printf '%s\\n' instead of echo to emit these:"
    echo "$output"
    false
  }
}
