# Troubleshooting

[Back to the README](../README.md)

Two known issues in the action itself, then the failures that come from configuration or the
platform.

## Known issues

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

### `web application scanning is not enabled for workspace '<tenant>'`

The workspace may not run web application scans, either because `scanCategories` does not
list it or because the start was refused for that reason. Nothing was registered or started.
Ask your Vulnara administrator to enable it, or remove `web-target-id`/`web-url`.

### `web-url requires web-ownership-consent: true`

`web-url` may register the URL as a web target, which records that you own the application or
are authorised to scan it. The action never gives that attestation for you: set
`web-ownership-consent: 'true'` (exactly that string), or pass an existing target as
`web-target-id`.

### `the workspace's plan limit for web application scanning is reached`

The plan's web scan minutes, parallel scans or web target count is used up; the code in
brackets says which. Wait for running scans to finish, remove unused web targets, or raise the
plan.

### `the web target does not resolve to public addresses only`

Only publicly reachable applications can be scanned. A preview behind a VPN, on a private
network or on an internal host name cannot be.

### `web-url '<url>' matches <n> web targets`

More than one web target has that base URL. Pass the one to scan as `web-target-id`.

### `timed out after <n>s waiting for '<codename>'`

The scan did not reach a terminal state inside `wait-timeout`. The scan itself keeps running on
the platform; open it at `<app-url>/repository-scans/<id>` to see where it got to, and raise
`wait-timeout` if the repository is simply large.
