# Vulnara Scan Action

Run a [Vulnara](https://vulnara.rso.dev) security scan on a branch from your CI,
authenticated with a **service account**, and optionally **fail the build** when
findings are found.

It talks to the Vulnara GraphQL API directly: it exchanges the service account
for a short-lived token, resolves the repository in Vulnara, starts a scan per
tool on the branch, waits for them to finish, and gates the job on the highest
finding severity. No extra binaries to download.

## Prerequisites

1. The repository already exists in Vulnara (add it under your workspace first).
2. A **service account** in Vulnara (Access & Security -> Service Accounts) with
   access to the tenant. Note its **username** and **token**.
3. The **scan tool(s)** you want to run (by name or id, e.g. `AEGIS`).
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
          scan-tools: AEGIS         # name or id; comma-separate for several
          fail-on: high             # fail the build on High or Critical findings
          # branch defaults to the branch that triggered the workflow
          # git-token-id: <id>      # required for private repositories
```

### Using outputs

```yaml
      - uses: theorigamicorporation/vulnara-action@v1
        id: vulnara
        with: { service-account: ..., token: ..., tenant: ..., scan-tools: AEGIS }
      - run: echo "highest severity = ${{ steps.vulnara.outputs.highest-severity }}"
```

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `service-account` | yes | | Service account username. |
| `token` | yes | | Service account token (use a secret). |
| `tenant` | yes | | Vulnara tenant (workspace) id. |
| `scan-tools` | yes | | Comma-separated scan tool names or ids. |
| `branch` | no | triggering branch | Branch to scan. |
| `repository` | no | current repo | `owner/name` to scan in Vulnara. |
| `git-token-id` | no | | Vulnara git token id (private repos). |
| `fail-on` | no | `critical` | Fail on findings at/above: `none` \| `low` \| `medium` \| `high` \| `critical`. |
| `create-issue` | no | `false` | Open an issue for findings. |
| `auto-remediate` | no | `false` | Open a fix PR (requires `create-issue`). |
| `wait-timeout` | no | `1800` | Max seconds to wait for scans. |
| `poll-interval` | no | `15` | Seconds between status checks. |
| `gateway-url` | no | prod | GraphQL gateway URL (override for non-prod). |
| `token-url` | no | prod | OAuth token endpoint (override for non-prod). |
| `oauth-client-id` | no | prod | OAuth client id for the token exchange. |

## Outputs

| Output | Description |
|---|---|
| `scan-result-ids` | Space-separated ids of the started scan results. |
| `highest-severity` | Highest finding severity found (or `none`). |
| `passed` | `true` if the scans passed the `fail-on` gate. |

## Notes

- The job runs until the scan(s) complete (up to `wait-timeout`), so it acts as a
  real security gate. The service-account token is refreshed automatically for
  long-running scans.
- The gate currently considers code/secret findings (`scanFindings`). Dependency
  and network findings can be added later.
- The repository must already exist in Vulnara, be **enabled**, and have access
  to the branch (a git token for private repos).
