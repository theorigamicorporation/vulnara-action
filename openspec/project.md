# Project Context

## Purpose

`vulnara-action` is a GitHub Action that runs a [Vulnara](https://vulnara.rso.dev)
security scan on a branch from CI and optionally fails the job when findings at or
above a configured severity are discovered. It is a thin CI client for the Vulnara
platform: it authenticates a Vulnara service account, resolves the repository and
scan tools in Vulnara, starts one scan per tool, waits for the scans to complete,
renders a GitHub job summary, and gates the build.

## Tech Stack

- **Runtime**: Docker container action (`runs.using: docker`, `image: Dockerfile`).
- **Base image**: `alpine:3.24` with `bash`, `curl`, `jq`, `tar`, `ca-certificates`.
- **Implementation language**: a single Bash script, `entrypoint.sh` (`set -euo pipefail`).
- **Remote API**: Vulnara GraphQL gateway (default `https://vulnara-gw.rso.dev/graphql`),
  called with `curl` and parsed with `jq`. No SDK, no compiled binaries, no package manager.
- **Auth**: OAuth 2.0 `client_credentials` grant against Authentik
  (default `https://auth.theorigamicorporation.com/application/o/token/`), exchanging a
  service-account username/token for a short-lived JWT.

## Project Conventions

### Layout

```
action.yml                 # Action metadata: inputs, outputs, branding, docker runner
Dockerfile                 # alpine + bash/curl/jq, ENTRYPOINT /entrypoint.sh
entrypoint.sh              # the entire implementation (auth, GraphQL, gate, summary)
README.md                  # user-facing docs: prerequisites, usage, inputs, outputs
examples/vulnara-scan.yml  # copy-paste workflow example
test/                      # offline bash test suite (runner, harness, stubs, fixtures)
.github/workflows/tests.yml # shellcheck + test suite + docker build on push and PR
```

There is no build step in this repository.

### Code Style

- Bash with `set -euo pipefail`; small single-purpose functions
  (`log`, `fail`, `step`, `info`, `ok`, `warn`, `gql`, `sev_rank`, ...).
- All GraphQL request bodies are constructed with `jq -n` so values are safely
  JSON-encoded; all responses are read with `jq -r`.
- Inputs are read through the `input()` helper because GitHub exposes Docker-action
  inputs as `INPUT_<NAME>` with dashes preserved (`INPUT_SERVICE-ACCOUNT`), which Bash
  parameter expansion cannot read; the helper uses `printenv` and falls back to the
  underscore form.
- User-facing log lines are prefixed `vulnara:` and written to stderr. GitHub workflow
  commands (`::error::`, `::warning::`, `::group::`) are used for annotations.
- Every host/endpoint has a production default in both `action.yml` and `entrypoint.sh`,
  and is overridable for non-prod (`app-url`, `gateway-url`, `token-url`, `oauth-client-id`).

### Git

- Conventional commit subjects (`feat:`, `fix:`, `docs:`), lower case, no scope required.
- The action is consumed by tag, e.g. `theorigamicorporation/vulnara-action@v1`.

### Testing

`test/run-tests.sh` runs a dependency-free bash test suite (only `bash` and `jq` are
needed); `test/run-tests.sh <file>` or `-f <substring>` narrows the run. Tests execute
`entrypoint.sh` with stubbed `curl` and `sleep` on `PATH`, so they never reach the
network: every API response comes from a JSON fixture under `test/fixtures/base`, which
a test can override per scenario. Inputs are injected with `env(1)` because bash cannot
export the dashed `INPUT_*` names. Each test carries a `# spec:` comment naming the
requirement and scenario it covers. Fixtures must stay free of real credentials, hosts
and tenant ids. The action is additionally exercised end-to-end by referencing the
repository from a workflow and pointing it at a non-prod Vulnara via the `*-url` inputs.

## Domain Context

- **Tenant / workspace**: every GraphQL request carries an `X-Tenant` header; the
  service account must belong to that tenant.
- **Repository**: a repository must already exist in Vulnara and be enabled before it
  can be scanned. Private repositories additionally need a Vulnara **git token id**
  so the platform can clone them.
- **Scan tool** (`dockerScanTools`): the scanners Vulnara can run, referenced by id or
  by name (e.g. `AEGIS`, `pdd`, `trivy`, `secret_scanner`). The action maps internal
  tool names to their user-facing codenames (Ripley, Bishop, Hicks, Ash) for display.
- **Scan result** (`scanResult`): one run of one tool against one branch; its `status`
  progresses to a terminal `SUCCESS`, `FAILED` or `CANCELLED`.
- **Finding** (`scanFindings`): a code/secret finding with a `severity`
  (`CRITICAL` > `HIGH` > `MEDIUM` > `LOW`), `file`, `line`, `confidence` and the
  commit it was found at. Dependency and network findings are out of scope today.

## Important Constraints

- Runs only on Linux runners (Docker container action).
- The job blocks for the whole scan duration, bounded by `wait-timeout` (default 1800s),
  polling every `poll-interval` seconds (default 15s).
- The JWT is refreshed automatically 120s before expiry so long scans do not fail.
- The detailed findings table in the job summary is capped at 50 located findings.

## External Dependencies

- Vulnara GraphQL gateway — repository/tool lookup, scan start, status polling, findings.
- Authentik OAuth token endpoint — service-account token exchange.
- GitHub Actions runtime — `INPUT_*`, `GITHUB_REF_NAME`, `GITHUB_REPOSITORY`,
  `GITHUB_OUTPUT`, `GITHUB_STEP_SUMMARY`.
