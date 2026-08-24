# Troubleshooting

[Back to the README](../README.md)

Three known issues in the action itself, then the failures that come from configuration or the
platform.

## Known issues

### A tool resolution failure passes the gate

The one to know about. Step 3 consumes the tool list with `done < <(resolve_tools)` at
`entrypoint.sh:248`, so `resolve_tools` runs in the subshell of a process substitution. When it
hits an unknown tool name it prints an `::error::` annotation and exits, but only that subshell
dies. The parent keeps running with an empty tool list: it starts no scans, reads no findings,
reports the highest severity as `none`, and **exits 0**. The job goes green having scanned
nothing, and `set -euo pipefail` does not catch it because the failure is not in the parent's
pipeline.

Symptoms: an `::error::scan tool '<name>' not found` annotation on a **successful** job, and
`vulnara:   ✓ 0 scan tool(s) selected` in the log.

Until it is fixed, assert on the output in a following step:

```yaml
      - uses: theorigamicorporation/vulnara-action@v1
        id: vulnara
        with: { service-account: ..., token: ..., tenant: ..., scan-tools: AEGIS }
      - name: Fail if no scan actually ran
        if: ${{ steps.vulnara.outputs.scan-result-ids == '' }}
        run: exit 1
```

### The wrong repository is scanned

Repository resolution at `entrypoint.sh:115-122` queries by repository **name** only, then
prefers the candidate whose git entity name equals the owner half of `repository`,
case-insensitively. If no candidate matches, it falls back to `.items[0]`, the first result the
API returned.

So when two repositories in the tenant share a name under different owners and the owner match
fails, for example because the entity is recorded in Vulnara under a different name than the
GitHub owner, the action can resolve, scan and gate on the other one.

The resolved repository is printed in step 2 as `Repository` and `Vulnara id`, and appears in
the job summary. Check it whenever a scan reports findings you do not recognise, or reports
none where you expected some.

### A multi-scanner run takes far longer than `wait-timeout`

All scans are started up front, but they are awaited one at a time, and `wait_scan` computes
its own start and deadline from `WAIT_TIMEOUT` at `entrypoint.sh:191-192`. The timeout is
therefore per scan, not per run: at the default 1800s, four scanners have a worst case of
roughly two hours before the step gives up.

Set `wait-timeout` to the budget you want for a single scanner, and bound the run as a whole
with the job's own `timeout-minutes`:

```yaml
jobs:
  scan:
    runs-on: ubuntu-latest
    timeout-minutes: 45
```

Because the scans run concurrently on the platform and only the waiting is sequential, the
wall-clock time is usually the slowest scan, not the sum. The compounding only shows up when
scans hang.

## Common failures

### `repository '<owner>/<name>' was not found in Vulnara`

The repository has not been added to the tenant, or the service account cannot see it. Add it
in Vulnara first, and check `tenant` matches the workspace it lives in.

### `could not authenticate the service account`

The `client_credentials` exchange returned no `access_token`. The response's
`error_description` or `error` is printed on the line above the failure. Usual causes: a
rotated token, a service account that is not a member of `tenant`, or `token-url` and
`oauth-client-id` left pointing at production while `gateway-url` points elsewhere. All of
them have to belong to the same environment.

### `GraphQL request failed`

Each error's `extensions.code` and `message` is printed above the failure. `UNAUTHENTICATED`
usually means the tenant and the service account do not match; `FORBIDDEN` means the account
lacks access to that repository or tool.

### A private repository fails to clone

The action warns `repository is private but no git-token-id was provided` and starts the scan
anyway. The scan then fails on the platform side and the job fails with
`scan for '<codename>' ended as FAILED`. Pass a valid `git-token-id`.

### `repository ... is disabled in Vulnara`

A warning, not an error, and the scan is still attempted, but the platform will usually reject
it. Enable the repository in Vulnara.

### `timed out after <n>s waiting for '<codename>'`

The scan did not reach a terminal state inside `wait-timeout`. The scan itself keeps running on
the platform; open it at `<app-url>/repository-scans/<id>` to see where it got to, and raise
`wait-timeout` if the repository is simply large.
