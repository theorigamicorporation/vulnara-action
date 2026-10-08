## Context

The gateway exposes web application scanning as `webTargets`/`webTarget`,
`createWebTarget(input: {name, baseUrl, ownershipConsent})`, `startWebScan(input:
{webTargetId}) -> WebScanTask { webScanResult { id status } }`, `webScanResult(id)` and
`dastFindings(list)`, filterable on `scanResultId` and `severity`. `scanCategories` answers what
the tenant may run, and lists `DAST` only once a scanner serves it for that tenant.

## Goals / Non-Goals

**Goals:** scan a deployed application from CI and gate on it, with registration of a new
target only on an explicit, per-workflow attestation; fail closed on every refusal.

**Non-Goals:** scope and excluded paths for a registered target (set them in the application),
triage from CI, honouring triage decisions in the gate (the repository gate does not either; one
gate semantics for both is the simpler contract), schedules.

## Decisions

### `web-url` needs `web-ownership-consent: true`, `web-target-id` does not

Registering a target is the moment the platform records an ownership attestation, and the
gateway refuses `createWebTarget` without `ownershipConsent: true`. The action must not supply
that attestation on the user's behalf, so `web-url` (which may register) requires the literal
string `true`, checked before any network call. Reusing an already registered target for the
URL also goes through `web-url`, and it requires the same flag: the workflow cannot know in
advance which of the two will happen, and one rule is easier to read than two.
`web-target-id` names a target someone already registered, with its attestation on file, so it
needs nothing more.

`web-target-id` and `web-url` together are refused: one run scans one target.

### Matching a URL to an existing target

`webTargets` is listed filtered on the URL's host and compared on a normalised key: scheme and
host lowercased, a trailing dot on the host dropped, an empty path read as `/`, the fragment
dropped. That is the subset of the platform's normalisation that matters for equality. One
match is reused; two or more fail the run and ask for `web-target-id`; none registers the URL,
named after the URL (truncated to 255 characters).

A URL carrying credentials is refused locally and is never echoed, because the log is
world-readable on a public repository.

### Fail closed before writing anything

`scanCategories` is read before the target is resolved, so a workspace without web application
scanning fails with a clear message before a target is registered. `startWebScan` remains the
authority: `NO_SCANNER_FOR_CATEGORY` from it fails with the same message. Every other start
refusal maps to its own message (`*LIMIT_EXCEEDED`, `WEB_TARGET_ADDRESS_REFUSED`, `NOT_FOUND`),
and the gateway's own error lines are printed beneath it.

### Waiting

The web scan is waited on by the existing `wait_scan` semantics: its own `wait-timeout` window,
polling every `poll-interval`, `FAILED`/`CANCELLED` failing the run. It is started after the
repository scans are started, so both kinds run concurrently on the platform; the action then
waits for the repository scans and the web scan in turn. The pending `run-wide-scan-deadline`
change, when applied, should fold the web scan into its outstanding set.

### Counting findings

Two requests, regardless of how many findings there are: one with four aliased
`dastFindings(...){total}` selections (one per severity, filtered on `scanResultId` and
`severity`), and, when any is non-zero, one with four aliased item selections of at most 50 each,
merged and capped at 50 for the summary table. Counting by `total` keeps the gate exact without
paging. A severity outside the four ranked ones is not counted, as for repository findings.

## Risks / Trade-offs

- A web-url run against a workspace with web scanning enabled but at its target cap fails at
  `createWebTarget` with the limit message; nothing is half-created.
- The summary prints matched URLs. They are URLs of the user's own application, the same class
  of information as the file paths repository findings print.
