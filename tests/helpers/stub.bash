#!/bin/bash

# Create a stub command that records its invocations and returns a canned response.
# Usage: stub_command <name> <exit_code> [stdout_output]
stub_command() {
  local name="$1"
  local exit_code="$2"
  local output="${3:-}"
  local stub_dir="${BATS_TEST_TMPDIR}/stubs"
  local stub_log="${BATS_TEST_TMPDIR}/${name}.log"

  mkdir -p "$stub_dir"
  cat > "${stub_dir}/${name}" <<STUB
#!/bin/bash
echo "\$@" >> "${stub_log}"
if [[ -n "${output}" ]]; then
  echo "${output}"
fi
exit ${exit_code}
STUB
  chmod +x "${stub_dir}/${name}"
  export PATH="${stub_dir}:${PATH}"
}

# Create a buildkite-agent stub that handles meta-data set/get.
# Meta-data is stored in files under BATS_TEST_TMPDIR/metadata/.
stub_buildkite_agent() {
  local stub_dir="${BATS_TEST_TMPDIR}/stubs"
  local metadata_dir="${BATS_TEST_TMPDIR}/metadata"
  local log="${BATS_TEST_TMPDIR}/buildkite-agent.log"

  mkdir -p "$stub_dir" "$metadata_dir"
  cat > "${stub_dir}/buildkite-agent" <<'STUB'
#!/bin/bash
METADATA_DIR="__METADATA_DIR__"
LOG="__LOG__"
echo "$@" >> "$LOG"
if [[ "$1" == "meta-data" && "$2" == "set" ]]; then
  echo "$4" > "${METADATA_DIR}/$3"
elif [[ "$1" == "meta-data" && "$2" == "get" ]]; then
  cat "${METADATA_DIR}/$3" 2>/dev/null
fi
STUB
  sed -i "s|__METADATA_DIR__|${metadata_dir}|g" "${stub_dir}/buildkite-agent"
  sed -i "s|__LOG__|${log}|g" "${stub_dir}/buildkite-agent"
  chmod +x "${stub_dir}/buildkite-agent"
  export PATH="${stub_dir}:${PATH}"
}

# Create a mergify stub that writes to GITHUB_OUTPUT like the real CLI.
stub_mergify_git_refs() {
  local base="$1"
  local head="$2"
  local stub_dir="${BATS_TEST_TMPDIR}/stubs"

  mkdir -p "$stub_dir"
  cat > "${stub_dir}/mergify" <<STUB
#!/bin/bash
if [[ "\$1" == "ci" && "\$2" == "git-refs" ]]; then
  echo "Base: ${base}"
  echo "Head: ${head}"
  if [[ -n "\${GITHUB_OUTPUT:-}" ]]; then
    echo "base=${base}" >> "\$GITHUB_OUTPUT"
    echo "head=${head}" >> "\$GITHUB_OUTPUT"
  fi
  exit 0
elif [[ "\$1" == "--version" ]]; then
  echo "mergify-cli 0.0.0-stub"
  exit 0
fi
echo "Unexpected args: \$@" >&2
exit 1
STUB
  chmod +x "${stub_dir}/mergify"
  export PATH="${stub_dir}:${PATH}"
}

# Create a mergify stub for scopes action.
stub_mergify_scopes() {
  local base="$1"
  local head="$2"
  local scopes_json="$3"  # e.g. '{"backend": "true", "frontend": "false"}'
  local stub_dir="${BATS_TEST_TMPDIR}/stubs"

  mkdir -p "$stub_dir"
  cat > "${stub_dir}/mergify" <<STUB
#!/bin/bash
if [[ "\$1" == "ci" && "\$2" == "scopes" ]]; then
  # Parse --write flag
  WRITE_FILE=""
  shift 2
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      --write) WRITE_FILE="\$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  echo "Base: ${base}"
  echo "Head: ${head}"
  if [[ -n "\${GITHUB_OUTPUT:-}" ]]; then
    echo "base=${base}" >> "\$GITHUB_OUTPUT"
    echo "head=${head}" >> "\$GITHUB_OUTPUT"
    local delimiter="ghadelimiter_test"
    echo "scopes<<\${delimiter}" >> "\$GITHUB_OUTPUT"
    echo '${scopes_json}' >> "\$GITHUB_OUTPUT"
    echo "\${delimiter}" >> "\$GITHUB_OUTPUT"
  fi
  if [[ -n "\$WRITE_FILE" ]]; then
    echo '{"scopes": ["backend"]}' > "\$WRITE_FILE"
  fi
  exit 0
elif [[ "\$1" == "ci" && "\$2" == "scopes-send" ]]; then
  echo "Scopes sent successfully"
  exit 0
elif [[ "\$1" == "--version" ]]; then
  echo "mergify-cli 0.0.0-stub"
  exit 0
fi
echo "Unexpected args: \$@" >&2
exit 1
STUB
  chmod +x "${stub_dir}/mergify"
  export PATH="${stub_dir}:${PATH}"
}

# Create a mergify stub for junit-process action.
stub_mergify_junit() {
  local exit_code="${1:-0}"
  local stub_dir="${BATS_TEST_TMPDIR}/stubs"
  local log="${BATS_TEST_TMPDIR}/mergify.log"

  mkdir -p "$stub_dir"
  cat > "${stub_dir}/mergify" <<STUB
#!/bin/bash
if [[ "\$1" == "ci" && "\$2" == "junit-process" ]]; then
  shift 2
  echo "junit-process \$@" >> "${log}"
  echo "MERGIFY_TOKEN=\${MERGIFY_TOKEN:-}" >> "${log}"
  echo "MERGIFY_API_URL=\${MERGIFY_API_URL:-}" >> "${log}"
  echo "MERGIFY_JOB_NAME=\${MERGIFY_JOB_NAME:-}" >> "${log}"
  echo "MERGIFY_TEST_EXIT_CODE=\${MERGIFY_TEST_EXIT_CODE:-}" >> "${log}"
  exit ${exit_code}
elif [[ "\$1" == "--version" ]]; then
  echo "mergify-cli 0.0.0-stub"
  exit 0
fi
echo "Unexpected args: \$@" >&2
exit 1
STUB
  chmod +x "${stub_dir}/mergify"
  export PATH="${stub_dir}:${PATH}"
}
