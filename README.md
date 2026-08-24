# Vulnara Scan Action

<table>
  <tr><th>CI</th><th>Code</th><th>OpenSpec</th><th>Security</th></tr>
  <tr>
    <td>
      <a href="../../actions/workflows/openspec-badges.yml"><img src="../../actions/workflows/openspec-badges.yml/badge.svg" alt="OpenSpec Badges"></a>
    </td>
    <td>
      <a href="../../tags"><img src="https://img.shields.io/github/v/tag/theorigamicorporation/vulnara-action?label=version&color=blue" alt="Latest tag"></a><br>
      <img src="https://img.shields.io/github/languages/top/theorigamicorporation/vulnara-action" alt="Top language"><br>
      <img src="https://img.shields.io/badge/alpine-3.20-blue.svg" alt="Base image"><br>
      <a href="../../commits/main"><img src="https://img.shields.io/github/last-commit/theorigamicorporation/vulnara-action" alt="Last commit"></a>
    </td>
    <td>
      <a href="openspec/specs/"><img src="docs/badges/specs.svg" alt="Specs"></a><br>
      <a href="openspec/specs/"><img src="docs/badges/requirements.svg" alt="Requirements"></a><br>
      <a href="openspec/specs/"><img src="docs/badges/scenarios.svg" alt="Scenarios"></a><br>
      <a href="openspec/"><img src="docs/badges/open-changes.svg" alt="Open Changes"></a>
    </td>
    <td>
      <a href="LICENSE"><img src="https://img.shields.io/github/license/theorigamicorporation/vulnara-action?color=green" alt="License"></a><br>
      <a href="SECURITY.md"><img src="https://img.shields.io/badge/security-policy-blue.svg" alt="Security policy"></a><br>
      <a href="../../security/advisories"><img src="https://img.shields.io/badge/disclosure-private-blue.svg" alt="Private disclosure"></a>
    </td>
  </tr>
</table>

Run a [Vulnara](https://vulnara.rso.dev) security scan on a branch from CI and gate the
build on what it finds. The action is a Docker container action built from a single Bash
script: it exchanges a Vulnara service account for a short-lived JWT, resolves the
repository and the requested scanners through the Vulnara GraphQL gateway, starts one scan
per scanner on the branch, blocks until they finish, writes a job summary linking every
finding to the offending line of code, and fails the job when the highest finding severity
reaches the `fail-on` threshold. No binaries are downloaded at run time: the image is
Alpine plus `bash`, `curl` and `jq`.

## How it works

The run is five numbered steps, each printed to the log with a `vulnara:` prefix.

1. **Authenticate.** An OAuth 2.0 `client_credentials` exchange against the Vulnara identity
   provider (`token-url`) trades `service-account` plus `token` for a JWT. The JWT is cached
   and re-exchanged automatically when fewer than 120 seconds of its `expires_in` remain, so
   a scan that outlives the token does not fail.
2. **Resolve the repository.** A `repositories` query filtered on `repositoryName` returns
   the candidates; the action picks the one whose git entity name matches the owner half of
   `repository`, case-insensitively. It then prints the Vulnara id, provider, visibility,
   languages and enabled flag, and warns if the repository is disabled, or is private with no
   `git-token-id`.
3. **Resolve the scanners.** `dockerScanTools` is queried once and each entry in `scan-tools`
   is matched against a tool id or a tool name (case-insensitive). An unknown name aborts the
   step and lists the available tools.
4. **Start and await the scans.** One `startRepositoryScan` mutation per scanner, all fired
   before any waiting begins, then `scanResult { status }` is polled every `poll-interval`
   seconds until each reaches `SUCCESS`. `FAILED` or `CANCELLED` fails the job immediately.
5. **Evaluate the findings.** `scanFindings` is queried per scan result, findings are counted
   per severity, the job summary is rendered, the three outputs are written, and the gate
   decides the exit code.

Every GraphQL request carries `Authorization: Bearer <jwt>` and `X-Tenant: <tenant>`. Request
bodies are built with `jq -n`, so no input is interpolated into a query string unencoded.

```
GitHub runner
  |
  |  1. client_credentials  ->  Vulnara identity provider (token-url)
  |  <- JWT
  |
  |  2-5. GraphQL over HTTPS ->  Vulnara gateway (gateway-url)
  |         repositories, dockerScanTools, startRepositoryScan,
  |         scanResult, scanFindings
  |
  v
GITHUB_OUTPUT + GITHUB_STEP_SUMMARY, exit 0 or 1
```

## Architecture

This action is a client, not a service. It holds no state, stores nothing, and runs no
scanner itself: the platform clones the repository and runs the scan containers. The only
two hosts it talks to are the gateway and the identity provider, and both are overridable
so the action can be pointed at a non-production Vulnara.

| Piece | Where it runs | What it does here |
|---|---|---|
| `action.yml` | GitHub | Declares the inputs, outputs and the Docker runner |
| `Dockerfile` | GitHub runner | `alpine:3.20` plus `bash`, `curl`, `jq`, `tar`, `ca-certificates` |
| `entrypoint.sh` | GitHub runner | The whole implementation: auth, GraphQL, polling, gate, summary |
| Vulnara gateway | Vulnara | The only API this action calls; owns authentication and tenancy |
| Vulnara scanners | Vulnara | Clone the branch and produce the findings |

For the platform as a whole, start at
[vulnara-dev](https://github.com/theorigamicorporation/vulnara-dev).

## Quick start

1. Add the repository to Vulnara and enable it.
2. Create a service account (Access & Security -> Service Accounts) in the tenant that owns
   the repository, and store its token as a GitHub Actions secret (`VULNARA_TOKEN`).
3. Copy [`examples/vulnara-scan.yml`](examples/vulnara-scan.yml) into `.github/workflows/`.
4. Set `tenant`, `scan-tools` and `fail-on`, and commit.

```yaml
name: Vulnara Scan
on:
  push:
    branches: [main]
  pull_request:

jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: theorigamicorporation/vulnara-action@v1
        with:
          service-account: ${{ vars.VULNARA_SERVICE_ACCOUNT }}
          token: ${{ secrets.VULNARA_TOKEN }}
          tenant: my-tenant
          scan-tools: AEGIS         # name or id; comma-separate for several
          fail-on: high             # fail the build on High or Critical findings
          # branch defaults to the branch that triggered the workflow
          # git-token-id: <id>      # required for private repositories
```

## Running

Prerequisites, all of them on the Vulnara side:

1. The repository exists in Vulnara, under the same owner name as on GitHub, and is
   **enabled**.
2. A service account in the tenant, with its username and token to hand.
3. The scanner names or ids you want to run.
4. For **private** repositories, a Vulnara git token and its id, passed as `git-token-id`.

The action runs on Linux runners only, because GitHub runs container actions only there. The
job blocks for the whole scan, so budget the workflow timeout accordingly, and see
[Troubleshooting](#troubleshooting) for how `wait-timeout` actually compounds across several
scanners.

### Using the outputs

```yaml
      - uses: theorigamicorporation/vulnara-action@v1
        id: vulnara
        with:
          service-account: ${{ vars.VULNARA_SERVICE_ACCOUNT }}
          token: ${{ secrets.VULNARA_TOKEN }}
          tenant: my-tenant
          scan-tools: AEGIS
          fail-on: none             # report, never fail
      - run: echo "highest severity = ${{ steps.vulnara.outputs.highest-severity }}"
```

With `fail-on: none` the gate never trips, so a later step can decide what to do with
`passed` and `highest-severity` itself.

## Configuration

### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `service-account` | yes | | Service account username. |
| `token` | yes | | Service account token (use a secret). |
| `tenant` | yes | | Vulnara tenant (workspace) id, sent as the `X-Tenant` header. |
| `scan-tools` | yes | | Comma-separated scanner names or ids. |
| `branch` | no | `GITHUB_REF_NAME` | Branch to scan. |
| `repository` | no | `GITHUB_REPOSITORY` | `owner/name` to scan in Vulnara. |
| `git-token-id` | no | | Vulnara git token id (required for private repositories). |
| `fail-on` | no | `critical` | Fail on findings at or above: `none` \| `low` \| `medium` \| `high` \| `critical`. |
| `create-issue` | no | `false` | Ask Vulnara to open an issue for findings. |
| `auto-remediate` | no | `false` | Ask Vulnara to open a fix pull request (requires `create-issue`). |
| `wait-timeout` | no | `1800` | Max seconds to wait for a scan, applied per scan. |
| `poll-interval` | no | `15` | Seconds between status checks. |
| `app-url` | no | `https://vulnara.rso.dev` | Web app base URL, used to build links in the job summary. |
| `gateway-url` | no | `https://vulnara-gw.rso.dev/graphql` | GraphQL gateway URL. |
| `token-url` | no | identity provider `/application/o/token/` | OAuth token endpoint. |
| `oauth-client-id` | no | the public Vulnara client id | OAuth client id used for the token exchange. |

`branch` and `repository` fail the run when neither the input nor the GitHub environment
variable is set, which is what happens if you run the container outside Actions without
setting them.

### Environment read from the runner

| Variable | Used for |
|---|---|
| `INPUT_<NAME>` | Every input. GitHub keeps the dashes (`INPUT_SERVICE-ACCOUNT`), which Bash cannot address, so they are read with `printenv` and fall back to the underscore form. |
| `GITHUB_REF_NAME` | Default for `branch`. |
| `GITHUB_REPOSITORY` | Default for `repository`. |
| `GITHUB_OUTPUT` | Where the three outputs are appended. Skipped if unset. |
| `GITHUB_STEP_SUMMARY` | Where the job summary is appended. Skipped if unset. |

### Outputs

| Output | Description |
|---|---|
| `scan-result-ids` | Space-separated ids of the scan results that were started. |
| `highest-severity` | Highest severity found across all scans, lower case, or `none`. |
| `passed` | `true` if the run passed the `fail-on` gate, `false` otherwise. |

## The severity gate

Severities are ranked, `fail-on` is mapped to a threshold rank, and the job fails when the
highest observed rank is **greater than or equal to** the threshold. The comparison is
case-insensitive, and any severity the action does not recognise ranks `0`, so it never trips
the gate and is not counted in the four severity totals.

| Severity | Rank | | `fail-on` | Threshold | Fails the job on |
|---|---|---|---|---|---|
| `CRITICAL` | 4 | | `critical` (default) | 4 | Critical |
| `HIGH` | 3 | | `high` | 3 | High, Critical |
| `MEDIUM` | 2 | | `medium` | 2 | Medium and above |
| `LOW` | 1 | | `low` | 1 | Any ranked finding |
| anything else | 0 | | `none` | 99 | Never |

Any other `fail-on` value aborts the run before the first network call with
`invalid fail-on '<value>' (expected none|low|medium|high|critical)`.

Two limits worth knowing:

- The gate looks only at `scanFindings`, which are code and secret findings. Dependency and
  network findings are not consulted, so they cannot fail the build today.
- A scan that ends `FAILED` or `CANCELLED` fails the job on its own, before any findings are
  read.

## Scanners

`scan-tools` accepts either the tool id or the tool name from Vulnara's `dockerScanTools`.
Matching on the name is case-insensitive. In the log and the job summary the action prints
the platform codename rather than the internal tool name:

| Tool name | Displayed as |
|---|---|
| `AEGIS`, `aegis` | Ripley |
| `pdd` | Bishop |
| `trivy` | Hicks |
| `secret_scanner` | Ash |
| `SECRET_SCANNER`, `Secret Scanner` | Secret Scanner |
| `personal_data_scanner` and its variants | Personal Data Scanner |
| anything else | the name unchanged |

The mapping mirrors the titles the web app uses. Note that the lower-case `secret_scanner`
maps to `Ash` while the upper-case and spaced spellings pass through as `Secret Scanner`.

## The job summary

When `GITHUB_STEP_SUMMARY` is set, the action appends:

- a verdict heading, passed or failed, and a table of repository, provider, visibility,
  branch, languages, the gate setting, the highest severity and the run duration
- the per-severity counts and the total
- one row per scan: codename, duration, finding count and a link to the scan in the platform
  at `<app-url>/repository-scans/<id>`
- a detailed table of findings that have a file, sorted by severity, capped at the top 50
  and stating how many were elided

Each detailed row links to the exact line at the scanned commit, using the repository's own
host: `/blob/<sha>/<file>#L<line>`, or `/-/blob/...` when the provider is `gitlab`. Findings
with no file are omitted from that table, though they still count towards the totals and the
gate.

## Development

There is no build step. `entrypoint.sh` is the whole implementation.

```bash
shellcheck -S warning entrypoint.sh
docker build -t vulnara-action:dev .
```

To exercise a change end to end, point a workflow at your branch and at a non-production
Vulnara:

```yaml
      - uses: theorigamicorporation/vulnara-action@my-branch
        with:
          gateway-url: https://gateway.example.test/graphql
          app-url: https://app.example.test
          token-url: https://auth.example.test/application/o/token/
          oauth-client-id: <non-prod client id>
```

Conventions that matter when editing the script: build every GraphQL body with `jq -n`, read
inputs through `input()` rather than `${INPUT_...}`, send user-facing lines to stderr with the
`vulnara:` prefix, and use `::error::` and `::warning::` for anything that should surface as a
GitHub annotation. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Testing

There is no automated suite on `main` yet, so a change is verified by:

1. `shellcheck -S warning entrypoint.sh`, which must be clean.
2. `docker build .`, which must succeed.
3. An end-to-end run against a non-production Vulnara, as above, covering at least one
   passing gate and one failing gate.

The behaviour any test has to satisfy is written down in `openspec/specs/`: 43 scenarios
across 15 requirements, each phrased as WHEN/THEN against observable output.

## Specifications

`openspec/specs/` is the source of truth for what this action does. Three capabilities:

| Capability | Covers |
|---|---|
| [`action-configuration`](openspec/specs/action-configuration/spec.md) | The action interface, how `INPUT_*` is read, defaults, validation and the non-prod overrides |
| [`scan-orchestration`](openspec/specs/scan-orchestration/spec.md) | Token exchange and refresh, tenant-scoped GraphQL, repository and tool resolution, starting scans, polling to a terminal state |
| [`findings-gate-reporting`](openspec/specs/findings-gate-reporting/spec.md) | Collecting findings, the gate, the outputs and the job summary |

Each file lists requirements as `### Requirement:` with `#### Scenario:` blocks underneath.
Read the requirement for the rule and the scenarios for the exact strings the action prints.
[`openspec/project.md`](openspec/project.md) carries the conventions and the domain glossary.
The badge counts come from `scripts/openspec_badges.py`, which the `OpenSpec Badges` workflow
regenerates whenever `openspec/` changes on `main`.

## Troubleshooting

**A tool-resolution failure passes the gate instead of failing it.** This is the one to know
about. Step 3 consumes the tool list with `done < <(resolve_tools)` at `entrypoint.sh:248`, so
`resolve_tools` runs in a subshell of a process substitution. When it hits an unknown tool
name it prints an `::error::` annotation and exits, but only that subshell dies: the parent
keeps running with an empty tool list, starts no scans, finds no findings, reports the highest
severity as `none` and **exits 0**. The job goes green with no scan having run. Until this is
fixed, check the log for `0 scan tool(s) selected`, or assert on the `scan-result-ids` output
in a following step:

```yaml
      - name: Fail if no scan actually ran
        if: ${{ steps.vulnara.outputs.scan-result-ids == '' }}
        run: exit 1
```

**The wrong repository is scanned.** Repository resolution at `entrypoint.sh:115-122` queries
by repository name only, then prefers the candidate whose git entity name matches your owner.
If no candidate matches, it falls back to `.items[0]`, the first result the API returned. When
two repositories in the tenant share a name under different owners and the owner match fails,
for example because the entity is recorded under a different name than the GitHub owner, the
action can resolve, scan and gate on the other one. The resolved repository is printed in step
2 as `Repository` and `Vulnara id`, and it is in the job summary. Check it if a scan reports
findings you do not recognise.

**A multi-scanner run takes far longer than `wait-timeout`.** All the scans are started up
front, but they are awaited one at a time, and `wait_scan` computes its own deadline from
`WAIT_TIMEOUT` at `entrypoint.sh:191-192`. The timeout is therefore per scan, not per run: at
the default 1800s, four scanners have a worst case of roughly two hours before the step gives
up. Set `wait-timeout` to the budget you want for a single scanner, and set the job's
`timeout-minutes` to bound the run as a whole.

**`repository '<owner>/<name>' was not found in Vulnara`.** The repository has not been added
to the tenant, or the service account cannot see it. Add it in Vulnara first, and check the
`tenant` input matches the workspace it lives in.

**`could not authenticate the service account`.** The `client_credentials` exchange returned
no `access_token`. The response's `error_description` is printed above the failure. Usual
causes: a rotated token, a service account that is not a member of `tenant`, or a
`token-url` or `oauth-client-id` left pointing at production while the gateway points
somewhere else. All four must belong to the same environment.

**A private repository fails to clone.** The action warns `repository is private but no
git-token-id was provided` and starts the scan anyway; the scan then fails on the platform
side. Pass a valid `git-token-id`.

**`repository ... is disabled in Vulnara`.** A warning, not an error, and the scan is still
attempted, but the platform will usually reject it. Enable the repository.

## Related repositories

Part of the [Vulnara](https://github.com/theorigamicorporation/vulnara-dev) platform.
Start there for the local stack and the architecture overview.

| Repo | Relationship |
|---|---|
| [vulnara-gateway-api](https://github.com/theorigamicorporation/vulnara-gateway-api) | The only API this action calls. Owns authentication, tenancy and every query and mutation used here |
| [vulnara-cli](https://github.com/theorigamicorporation/vulnara-cli) | The terminal equivalent of this action against the same gateway |
| [vulnara-dev](https://github.com/theorigamicorporation/vulnara-dev) | Local stack, for running a non-production gateway to develop against |

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for branch
naming, commit format and the OpenSpec workflow, and [SECURITY.md](SECURITY.md) for the
private disclosure route, which is where suspected vulnerabilities go instead of the issue
tracker.

This repository is public. Keep examples, fixtures and documentation free of real tenant ids,
hostnames and credentials.

## License

[MIT](LICENSE). Copyright (c) 2026 The Origami Corporation.
