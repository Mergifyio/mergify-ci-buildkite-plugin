# Mergify CI Buildkite Plugin

A Buildkite plugin for integrating with [Mergify CI Insights](https://mergify.com) — upload JUnit test reports, detect pull request scopes, and upload scopes to Mergify Merge Queue.

## Actions

### `junit-process`

Process JUnit XML test reports and upload them to Mergify CI Insights. Detects silent test failures automatically using the step's exit code.

```yaml
steps:
  - label: "Run tests"
    command: pytest --junitxml=reports/junit.xml
    plugins:
      - mergifyio/mergify-ci#v1:
          action: junit-process
          report_path: "reports/*.xml"
          token: "${MERGIFY_CI_TOKEN}"
```

### `scopes`

Detect which code scopes are affected by a pull request and upload them to the Mergify API.

```yaml
steps:
  - label: "Detect scopes"
    plugins:
      - mergifyio/mergify-ci#v1:
          action: scopes
          token: "${MERGIFY_CI_TOKEN}"
```

### `scopes-git-refs`

Return the merge-queue-aware base and head SHAs. Results are stored as Buildkite meta-data (`mergify-ci.base`, `mergify-ci.head`) for use by subsequent steps.

```yaml
steps:
  - label: "Get git refs"
    key: git-refs
    plugins:
      - mergifyio/mergify-ci#v1:
          action: scopes-git-refs
```

### `scopes-upload`

Upload pre-computed scopes to the Mergify API. Requires a prior `scopes-git-refs` step.

```yaml
steps:
  - label: "Get git refs"
    key: git-refs
    plugins:
      - mergifyio/mergify-ci#v1:
          action: scopes-git-refs

  - label: "Upload scopes"
    depends_on: git-refs
    plugins:
      - mergifyio/mergify-ci#v1:
          action: scopes-upload
          token: "${MERGIFY_CI_TOKEN}"
          scopes: "backend,frontend"
```

### Using scopes to conditionally run steps

Detect scopes first, then use the meta-data to skip steps unaffected by the change:

```yaml
steps:
  - label: "Detect scopes"
    key: scopes
    plugins:
      - mergifyio/mergify-ci#v1:
          action: scopes
          token: "${MERGIFY_CI_TOKEN}"

  - label: "Backend tests"
    depends_on: scopes
    command: pytest tests/backend/
    if: build.env("BUILDKITE_TRIGGERED_FROM_BUILD_PIPELINE_SLUG") != null || build.pull_request.id != null
    plugins:
      - mergifyio/mergify-ci#v1:
          action: junit-process
          report_path: "reports/*.xml"
          token: "${MERGIFY_CI_TOKEN}"
    # Use a dynamic pipeline or script to check scopes:
    # SCOPES=$(buildkite-agent meta-data get "mergify-ci.scopes")
    # echo "$SCOPES" | jq -e '.backend == "true"'

  - label: "Frontend tests"
    depends_on: scopes
    command: npm test
    plugins:
      - mergifyio/mergify-ci#v1:
          action: junit-process
          report_path: "reports/*.xml"
          token: "${MERGIFY_CI_TOKEN}"
    # SCOPES=$(buildkite-agent meta-data get "mergify-ci.scopes")
    # echo "$SCOPES" | jq -e '.frontend == "true"'
```

For full conditional control, use a [dynamic pipeline](https://buildkite.com/docs/pipelines/defining-steps#dynamic-pipelines) that reads the scopes meta-data and only uploads the relevant steps:

```bash
#!/bin/bash
# .buildkite/dynamic-pipeline.sh
SCOPES=$(buildkite-agent meta-data get "mergify-ci.scopes")

if echo "$SCOPES" | jq -e '.backend == "true"' > /dev/null 2>&1; then
  cat <<'YAML'
  - label: "Backend tests"
    command: pytest tests/backend/
    plugins:
      - mergifyio/mergify-ci#v1:
          action: junit-process
          report_path: "reports/*.xml"
          token: "${MERGIFY_CI_TOKEN}"
YAML
fi

if echo "$SCOPES" | jq -e '.frontend == "true"' > /dev/null 2>&1; then
  cat <<'YAML'
  - label: "Frontend tests"
    command: npm test
    plugins:
      - mergifyio/mergify-ci#v1:
          action: junit-process
          report_path: "reports/*.xml"
          token: "${MERGIFY_CI_TOKEN}"
YAML
fi
```

```yaml
# pipeline.yml
steps:
  - label: "Detect scopes"
    key: scopes
    plugins:
      - mergifyio/mergify-ci#v1:
          action: scopes
          token: "${MERGIFY_CI_TOKEN}"

  - label: "Upload pipeline"
    depends_on: scopes
    command: .buildkite/dynamic-pipeline.sh | buildkite-agent pipeline upload
```

## Configuration

| Property | Required | Default | Description |
|----------|----------|---------|-------------|
| `action` | yes | — | `junit-process`, `scopes`, `scopes-git-refs`, or `scopes-upload` |
| `token` | for API calls | — | Mergify CI authentication token |
| `report_path` | for junit-process | — | Glob path to JUnit XML files |
| `scopes` | for scopes-upload | — | Comma-separated list of scopes |
| `mergify_api_url` | no | `https://api.mergify.com` | Mergify API endpoint |
| `job_name` | no | Step label | Override job name (useful for matrix builds) |
| `mergify_config_path` | no | — | Path to `.mergify.yml` configuration file |
| `python_version` | no | `3.13` | Python version for `mergify-cli`. Uses `uv` to download it if needed. |

## Meta-data

The plugin stores the following values via `buildkite-agent meta-data`:

| Key | Set by | Description |
|-----|--------|-------------|
| `mergify-ci.base` | `scopes`, `scopes-git-refs` | Merge-queue-aware base SHA |
| `mergify-ci.head` | `scopes`, `scopes-git-refs` | Merge-queue-aware head SHA |
| `mergify-ci.scopes` | `scopes` | JSON mapping of scope names to "true"/"false" |

## Requirements

- Python 3.x on the Buildkite agent
- `curl` (for installing `uv`)
- `jq` (for JSON processing in `scopes-upload`)

## Development

### Running tests

```bash
bats tests/
```

## License

Apache 2.0 — see [LICENSE](LICENSE).
