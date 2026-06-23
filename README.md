# Vulnara Scan Action

Run a [Vulnara](https://vulnara.rso.dev) security scan on a branch from your CI,
authenticated with a **service account**, and optionally **fail the build** when
findings are found.

Under the hood it wraps [`vulnara-cli`](https://github.com/theorigamicorporation/vulnara-cli):
it authenticates the service account, resolves the repository in Vulnara, starts
a scan per tool on the branch, waits for them to finish, and gates the job on the
highest finding severity.

## Prerequisites

1. The repository already exists in Vulnara (add it under your workspace first).
2. A **service account** in Vulnara (Settings -> Service Accounts) with access to
   the tenant. Note its **username** and **token**.
3. The **scan tool id(s)** you want to run (from your scan tools in Vulnara).
4. For **private** repositories, a Vulnara **git token** and its id.

Store the service account token as a GitHub Actions secret (e.g. `VULNARA_TOKEN`).

## Usage

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
          scan-tools: '11111111-2222-3333-4444-555555555555'
          fail-on: high            # fail the build on High or Critical findings
          # branch defaults to the branch that triggered the workflow
          # git-token-id: <id>     # required for private repositories
```

### Outputs

```yaml
      - uses: theorigamicorporation/vulnara-action@v1
        id: vulnara
        with: { service-account: ..., token: ..., tenant: ..., scan-tools: ... }
      - run: echo "highest severity = ${{ steps.vulnara.outputs.highest-severity }}"
```

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `service-account` | yes | | Service account username. |
| `token` | yes | | Service account token (use a secret). |
| `tenant` | yes | | Vulnara tenant (workspace) id. |
| `scan-tools` | yes | | Comma-separated scan tool ids to run. |
| `branch` | no | triggering branch | Branch to scan. |
| `repository` | no | current repo | `owner/name` to scan in Vulnara. |
| `git-token-id` | no | | Vulnara git token id (private repos). |
| `fail-on` | no | `critical` | Fail on findings at/above: `none` \| `low` \| `medium` \| `high` \| `critical`. |
| `create-issue` | no | `false` | Open an issue for findings. |
| `auto-remediate` | no | `false` | Open a fix PR (requires `create-issue`). |
| `wait-timeout` | no | `1800` | Max seconds to wait for scans. |
| `poll-interval` | no | `15` | Seconds between status checks. |
| `cli-version` | no | `latest` | `vulnara-cli` release tag to use. |
| `cli-token` | no | | Token to download the CLI (only if its repo is private). |

## Outputs

| Output | Description |
|---|---|
| `scan-result-ids` | Space-separated ids of the started scan results. |
| `highest-severity` | Highest finding severity found (or `none`). |
| `passed` | `true` if the scans passed the `fail-on` gate. |

## Notes

- The job runs until the scan(s) complete (up to `wait-timeout`), so it acts as a
  real security gate.
- The gate currently considers code/secret findings (`scanFindings`). Dependency
  and network findings can be added later.
- `scan-tools` takes tool **ids**; scanning by tool **name** will be supported once
  `vulnara-cli` exposes a scan-tools query.
- Targets the production Vulnara API (`vulnara-gw.rso.dev`), matching `vulnara-cli`.
