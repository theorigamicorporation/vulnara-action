## Why

Web application scanning is in beta on the platform (OpenProject #1301, part of the DAST beta
under #778): a workspace registers a web target, starts a web scan of it and triages the
findings. The natural place to run one from CI is right after a preview or staging deploy, and
today the action can only scan a repository. A team that wants the deployed application checked
on every pull request has to script the gateway themselves, and has nothing that gates the build
on what the scan found.

## What Changes

- New optional inputs:
  - `web-target-id`: scan an existing web target.
  - `web-url` with `web-ownership-consent`: scan the web target registered for that URL,
    registering it first when the workspace has none. Registering a target is an ownership
    attestation, so `web-url` is refused unless `web-ownership-consent` is exactly `true`.
- `scan-tools` is no longer marked required in `action.yml`: a run needs `scan-tools`, a web
  target, or both. A run with neither still fails with `scan-tools is required`. Every
  workflow that passes `scan-tools` today behaves exactly as before.
- A web-only run (no `scan-tools`) does not resolve a repository or branch.
- Before registering or scanning anything the action checks that the workspace may run web
  application scans (`scanCategories` lists `DAST`) and fails closed with a clear message when
  it may not. A start refused with `NO_SCANNER_FOR_CATEGORY`, a plan limit, a non-public target
  address or a missing target fails with a message saying which.
- The web scan is started with `startWebScan`, waited on with the same `wait-timeout` and
  `poll-interval` as each repository scan, and its findings are counted by severity.
- The findings of the web scan feed the same `fail-on` gate, `highest-severity` and `passed`
  outputs as repository findings. New outputs `web-target-id` and `web-scan-result-id`.
- The job summary gains a `Web application` section: the target, the scan's duration and
  status, the findings by severity, and the top findings (severity, name, matched URL, CVE/CWE).
- Nothing names the scanner that ran the web scan; it is labelled `Web application`.

Purely additive: no existing input changes meaning, and no existing output changes value for a
run that does not set a web input.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `action-configuration`: the web inputs, their validation and the relaxed `scan-tools`
  requirement.
- `scan-orchestration`: resolving or registering the web target, the availability check, and
  starting and waiting for the web scan.
- `findings-gate-reporting`: web findings counted, gated, published and summarised.

## Impact

`action.yml`, `entrypoint.sh`, `test/` (stub operations, fixtures, a new `web_test.sh`),
`README.md`, `docs/configuration.md`, `docs/reference.md`, `docs/architecture.md`,
`docs/troubleshooting.md`, `examples/vulnara-scan.yml`, `openspec/project.md`.
