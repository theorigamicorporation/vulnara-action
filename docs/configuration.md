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
| `scan-tools` | no | | Comma-separated scan tool ids to run on the repository. Required unless `web-target-id` or `web-url` is set. See [Reference](reference.md#scanners). |
| `branch` | no | the [platform's](#ci-platforms) branch | Branch to scan. |
| `repository` | no | the [platform's](#ci-platforms) repository | `owner/name` to resolve in Vulnara. Azure DevOps also takes `org/project/repo` or `project/repo`. See [Reference](reference.md#resolving-the-repository). |
| `git-token-id` | no | | Vulnara git token id. Required for private repositories. |
| `fail-on` | no | `critical` | Fail at or above: `none` \| `low` \| `medium` \| `high` \| `critical`. See [the gate](reference.md#the-severity-gate). |
| `create-issue` | no | `false` | Ask Vulnara to open an issue for findings. |
| `auto-remediate` | no | `false` | Ask Vulnara to open a fix pull request. Requires `create-issue`. |
| `wait-timeout` | no | `1800` | Max seconds to wait for a scan. Applied **per scan**, not per run. |
| `poll-interval` | no | `15` | Seconds between status checks. |
| `web-target-id` | no | | Id of an existing web target to run a web application scan on. Mutually exclusive with `web-url`. See [Reference](reference.md#web-application-scans). |
| `web-url` | no | | Base URL of a web application to scan. The web target registered for it is reused, or the URL is registered as one. Requires `web-ownership-consent: true`. |
| `web-ownership-consent` | no | `false` | Exactly `true` to confirm you own the application at `web-url` or are authorised to scan it. Registering a target records this attestation. Not needed for `web-target-id`. |
| `app-url` | no | `https://vulnara.rso.dev` | Web app base URL, used only to build links in the job summary. A trailing slash is stripped. |
| `gateway-url` | no | `https://vulnara-gw.rso.dev/graphql` | GraphQL gateway URL. |
| `token-url` | no | the production identity provider `/application/o/token/` endpoint | OAuth token endpoint. |
| `oauth-client-id` | no | the public Vulnara client id | OAuth client id used for the token exchange. |
| `ci-platform` | no | detected | `github` \| `gitlab` \| `none`. Overrides [platform detection](#ci-platforms). An unknown value fails the run before any request. |
| `report-dir` | no | `$CI_PROJECT_DIR/.vulnara` on GitLab | Where `outputs.env` and `summary.md` are written on platforms without a step summary. Ignored on GitHub. On `none`, files are written only when this is set. |

The four `*-url` and `oauth-client-id` inputs exist so the action can be pointed at a
non-production Vulnara. They belong to one environment as a set: mixing a production
`token-url` with a staging `gateway-url` fails authentication rather than falling back.

### Validation

Validation happens before the first network call. Messages are shown in GitHub's annotation
syntax; on other platforms `::error::` is an `ERROR: ` prefix.

| Condition | Result |
|---|---|
| `service-account`, `token` or `tenant` empty | `::error::<name> is required` |
| `scan-tools`, `web-target-id` and `web-url` all empty | `::error::scan-tools is required` |
| `scan-tools` set, `repository` empty and no [platform default](#ci-platforms) | `::error::repository could not be determined` |
| `scan-tools` set, `branch` empty and no [platform default](#ci-platforms) | `::error::branch could not be determined` |
| `web-target-id` and `web-url` both set | `::error::set web-target-id or web-url, not both: ...` |
| `web-target-id` not an id | `::error::web-target-id '<value>' is not a web target id. ...` |
| `web-url` carries credentials | `::error::web-url must not carry credentials ...` (the URL is not echoed) |
| `web-url` not `http(s)://` | `::error::web-url '<value>' is not an http(s) URL` |
| `web-url` set, `web-ownership-consent` not exactly `true` | `::error::web-url requires web-ownership-consent: true. ...` |
| `ci-platform` not `github`, `gitlab` or `none` | `invalid ci-platform '<value>' (expected github\|gitlab\|none)` |
| `fail-on` not one of the five accepted values | `::error::invalid fail-on '<value>' (expected none\|low\|medium\|high\|critical)` |

`create-issue`, `auto-remediate` and `web-ownership-consent` are compared literally against
`true`; any other value, including `TRUE`, is treated as false.

## Environment read from the runner

| Variable | Used for |
|---|---|
| `INPUT_<NAME>` | Every input. GitHub keeps the dashes (`INPUT_SERVICE-ACCOUNT`), which Bash parameter expansion cannot address, so inputs are read with `printenv` and fall back to the underscore form `INPUT_SERVICE_ACCOUNT`. |
| `GITHUB_ACTIONS`, `GITLAB_CI` | Detecting the CI platform. |
| `GITHUB_REF_NAME` | Default for `branch` on GitHub. |
| `GITHUB_REPOSITORY` | Default for `repository` on GitHub. |
| `GITHUB_OUTPUT` | Where the outputs are appended on GitHub. Skipped when unset. |
| `GITHUB_STEP_SUMMARY` | Where the job summary is appended on GitHub. Skipped when unset. |
| `CI_MERGE_REQUEST_SOURCE_BRANCH_NAME`, then `CI_COMMIT_BRANCH` | Default for `branch` on GitLab. A tag pipeline has neither, so `branch` must be passed. |
| `CI_PROJECT_PATH` | Default for `repository` on GitLab, subgroups included (`group/sub/project`). |
| `CI_PROJECT_DIR` | Parent of the default `report-dir` on GitLab. |

## CI platforms

The platform is detected before any other input is read, and printed in the banner as
`vulnara: CI platform: <name>`. `ci-platform` overrides it.

| Platform | Detected when | Errors and warnings | Outputs | Summary |
|---|---|---|---|---|
| `github` | `GITHUB_ACTIONS=true` | `::error::` / `::warning::` annotations | `GITHUB_OUTPUT` | `GITHUB_STEP_SUMMARY` |
| `gitlab` | `GITLAB_CI=true` | `ERROR:` / `WARNING:` lines | `<report-dir>/outputs.env` | `<report-dir>/summary.md`, also printed in a collapsed log section |
| `none` | neither | `ERROR:` / `WARNING:` lines | `<report-dir>/outputs.env` if `report-dir` is set | `<report-dir>/summary.md` if `report-dir` is set |

Off GitHub, `outputs.env` is a GitLab dotenv report: each output is named `VULNARA_` plus its
name upper-cased with dashes replaced by underscores, for example
`VULNARA_HIGHEST_SEVERITY=critical`. Publish it with `artifacts: reports: dotenv:` and the
values reach later jobs in the pipeline.

Without `branch` and `repository`, a `none` run has nothing to default them from, so pass both.

## Outputs

| Output | Description |
|---|---|
| `scan-result-ids` | Space-separated ids of the repository scan results that were started. Empty if none started. |
| `highest-severity` | Highest severity found across all scans, lower case, or `none`. |
| `passed` | `true` if the run passed the `fail-on` gate, `false` otherwise. |
| `web-target-id` | Id of the web target that was scanned. Written only when a web application scan ran. |
| `web-scan-result-id` | Id of the web application scan result. Written only when one ran. `scan-result-ids` stays repository scans only. |

With `fail-on: none` the gate never trips, so the job stays green and a later step can decide
what to do with `passed` and `highest-severity` itself:

```yaml
      - uses: theorigamicorporation/vulnara-action@v1
        id: vulnara
        with:
          service-account: ${{ vars.VULNARA_SERVICE_ACCOUNT }}
          token: ${{ secrets.VULNARA_TOKEN }}
          tenant: my-tenant
          scan-tools: 11111111-2222-3333-4444-555555555555
          fail-on: none
      - run: echo "highest severity = ${{ steps.vulnara.outputs.highest-severity }}"
```

`action.yml`, this page and
[`openspec/specs/action-configuration/spec.md`](../openspec/specs/action-configuration/spec.md)
all enumerate the inputs. A new input has to appear in all three.
