# Troubleshooting

[Back to the README](../README.md)

One known issue in the action itself, then the failures that come from configuration or the
platform.

## Known issues

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

### `repository '<owner>/<name>' was not found under '<owner>' in Vulnara`

Vulnara holds a repository with that name, but under a different workspace than the owner half of
`repository`. The failure lists the workspaces it found. Usually the workspace is recorded in
Vulnara under a different name than the git owner: fix `repository`, or make the names match.
The action never scans a same-named repository under another owner in place of the one asked for.

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
`scan for '<category>' ended as FAILED`. Pass a valid `git-token-id`.

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

### `timed out after <n>s waiting for '<category>'`

The scan did not reach a terminal state inside `wait-timeout`. The scan itself keeps running on
the platform; open it at `<app-url>/repository-scans/<id>` to see where it got to, and raise
`wait-timeout` if the repository is simply large.
