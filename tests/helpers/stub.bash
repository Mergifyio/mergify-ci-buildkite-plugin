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

# Stub `curl` for the environment hook. Records argv to curl.log, then prints a
# fake install.sh on stdout. When the hook pipes it to `sh`, the script installs
# a `mergify` stub into MERGIFY_INSTALL_DIR and echoes the MERGIFY_VERSION the
# hook exported, so tests can assert both the install.sh URL and the version.
stub_curl_install() {
  local stub_dir="${BATS_TEST_TMPDIR}/stubs"
  mkdir -p "$stub_dir"
  # Fully-quoted heredoc: nothing expands at stub-creation time. The inner
  # 'SCRIPT' heredoc keeps ${MERGIFY_*} literal on stdout so they expand only
  # in the `sh` that consumes the piped installer.
  cat > "${stub_dir}/curl" <<'STUB'
#!/bin/bash
echo "$@" >> "${BATS_TEST_TMPDIR}/curl.log"
cat <<'SCRIPT'
#!/bin/sh
mkdir -p "${MERGIFY_INSTALL_DIR}"
printf '#!/bin/bash\necho "mergify-cli 0.0.0-stub"\n' > "${MERGIFY_INSTALL_DIR}/mergify"
chmod +x "${MERGIFY_INSTALL_DIR}/mergify"
echo "installed MERGIFY_VERSION=${MERGIFY_VERSION}"
SCRIPT
STUB
  chmod +x "${stub_dir}/curl"
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
elif [[ "$1" == "annotate" ]]; then
  echo "$2" > "${METADATA_DIR}/annotation"
fi
STUB
  sed -i "s|__METADATA_DIR__|${metadata_dir}|g" "${stub_dir}/buildkite-agent"
  sed -i "s|__LOG__|${log}|g" "${stub_dir}/buildkite-agent"
  chmod +x "${stub_dir}/buildkite-agent"
  export PATH="${stub_dir}:${PATH}"
}

# Create a mergify stub that mimics the real CLI: when BUILDKITE=true,
# the CLI writes base/head/source directly to buildkite meta-data.
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
  if [[ "\${BUILDKITE:-}" == "true" ]]; then
    buildkite-agent meta-data set "mergify-ci.base" "${base}"
    buildkite-agent meta-data set "mergify-ci.head" "${head}"
    buildkite-agent meta-data set "mergify-ci.source" "buildkite_pull_request"
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

# Create a mergify stub for scopes action. Mimics the real CLI which,
# when BUILDKITE=true, writes base/head/source/scopes meta-data and a
# Buildkite annotation directly.
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
  if [[ "\${BUILDKITE:-}" == "true" ]]; then
    buildkite-agent meta-data set "mergify-ci.base" "${base}"
    buildkite-agent meta-data set "mergify-ci.head" "${head}"
    buildkite-agent meta-data set "mergify-ci.source" "buildkite_pull_request"
    buildkite-agent meta-data set "mergify-ci.scopes" '${scopes_json}'
    buildkite-agent annotate "stub-annotation" --style "info" --context "mergify-ci-scopes"
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
  echo "MERGIFY_TEST_JOB_NAME=\${MERGIFY_TEST_JOB_NAME:-}" >> "${log}"
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
