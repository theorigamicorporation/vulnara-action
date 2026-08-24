# Configuration

[Back to the README](../README.md)

Every value the action reads: the action inputs, the runner environment it falls back to, and
the outputs it writes.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `service-account` | yes | | Service account username. |
| `token` | yes | | Service account token. Pass it from a GitHub Actions secret. |
| `tenant` | yes | | Vulnara tenant (workspace) id, sent as the `X-Tenant` header on every request. |
| `scan-tools` | yes | | Comma-separated scanner names or ids. See [Reference](reference.md#scanners). |
| `branch` | no | `GITHUB_REF_NAME` | Branch to scan. |
| `repository` | no | `GITHUB_REPOSITORY` | `owner/name` to resolve in Vulnara. |
| `git-token-id` | no | | Vulnara git token id. Required for private repositories. |
| `fail-on` | no | `critical` | Fail at or above: `none` \| `low` \| `medium` \| `high` \| `critical`. See [the gate](reference.md#the-severity-gate). |
| `create-issue` | no | `false` | Ask Vulnara to open an issue for findings. |
| `auto-remediate` | no | `false` | Ask Vulnara to open a fix pull request. Requires `create-issue`. |
| `wait-timeout` | no | `1800` | Max seconds to wait for a scan. Applied **per scan**, not per run. |
| `poll-interval` | no | `15` | Seconds between status checks. |
| `app-url` | no | `https://vulnara.rso.dev` | Web app base URL, used only to build links in the job summary. A trailing slash is stripped. |
| `gateway-url` | no | `https://vulnara-gw.rso.dev/graphql` | GraphQL gateway URL. |
| `token-url` | no | the production identity provider `/application/o/token/` endpoint | OAuth token endpoint. |
| `oauth-client-id` | no | the public Vulnara client id | OAuth client id used for the token exchange. |

The four `*-url` and `oauth-client-id` inputs exist so the action can be pointed at a
non-production Vulnara. They belong to one environment as a set: mixing a production
`token-url` with a staging `gateway-url` fails authentication rather than falling back.

### Validation

Validation happens before the first network call.

| Condition | Result |
|---|---|
| `service-account`, `token`, `tenant` or `scan-tools` empty | `::error::<name> is required` |
| `repository` empty and `GITHUB_REPOSITORY` unset | `::error::repository could not be determined` |
| `branch` empty and `GITHUB_REF_NAME` unset | `::error::branch could not be determined` |
| `fail-on` not one of the five accepted values | `::error::invalid fail-on '<value>' (expected none\|low\|medium\|high\|critical)` |

`create-issue` and `auto-remediate` are compared literally against `true`; any other value,
including `TRUE`, is treated as false.

## Environment read from the runner

| Variable | Used for |
|---|---|
| `INPUT_<NAME>` | Every input. GitHub keeps the dashes (`INPUT_SERVICE-ACCOUNT`), which Bash parameter expansion cannot address, so inputs are read with `printenv` and fall back to the underscore form `INPUT_SERVICE_ACCOUNT`. |
| `GITHUB_REF_NAME` | Default for `branch`. |
| `GITHUB_REPOSITORY` | Default for `repository`. |
| `GITHUB_OUTPUT` | Where the outputs are appended. Skipped when unset. |
| `GITHUB_STEP_SUMMARY` | Where the job summary is appended. Skipped when unset. |

Both `GITHUB_OUTPUT` and `GITHUB_STEP_SUMMARY` being optional is what makes the container
runnable outside Actions, provided `branch` and `repository` are passed explicitly.

## Outputs

| Output | Description |
|---|---|
| `scan-result-ids` | Space-separated ids of the scan results that were started. Empty if none started. |
| `highest-severity` | Highest severity found across all scans, lower case, or `none`. |
| `passed` | `true` if the run passed the `fail-on` gate, `false` otherwise. |

With `fail-on: none` the gate never trips, so the job stays green and a later step can decide
what to do with `passed` and `highest-severity` itself:

```yaml
      - uses: theorigamicorporation/vulnara-action@v1
        id: vulnara
        with:
          service-account: ${{ vars.VULNARA_SERVICE_ACCOUNT }}
          token: ${{ secrets.VULNARA_TOKEN }}
          tenant: my-tenant
          scan-tools: AEGIS
          fail-on: none
      - run: echo "highest severity = ${{ steps.vulnara.outputs.highest-severity }}"
```

`action.yml`, this page and
[`openspec/specs/action-configuration/spec.md`](../openspec/specs/action-configuration/spec.md)
all enumerate the inputs. A new input has to appear in all three.
