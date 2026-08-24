## Context

Step 4 starts one scan per tool in a loop, then waits in a second loop that calls `wait_scan`
once per scan. `wait_scan` is self-contained: it takes a scan result id and a label, sets
`start` to now and `deadline` to `start + WAIT_TIMEOUT`, and polls until that scan is terminal.
Nothing is shared between calls, so each scan gets a full timeout and the run gets none.

The scans themselves run concurrently on the platform. Only the waiting is sequential, so on a
healthy run the wall-clock cost is the slowest scan and the defect is invisible. It surfaces
when scans hang, which is exactly when the job needs to give up cleanly.

## Goals / Non-Goals

**Goals:**

- One deadline for the whole waiting phase, derived from `wait-timeout`.
- Report a terminal failure as soon as it is observed on any scan.
- Keep per-scan durations and transition logs, which the job summary already renders.

**Non-Goals:**

- Background jobs or subshell parallelism. The waiting is already effectively parallel once the
  polling is interleaved, and a `fail` inside a background job cannot stop the parent, which is
  the same hazard already fixed in tool resolution.
- A separate per-scan timeout input. Two timeout knobs on a CI action is a worse interface than
  one, and the run-wide bound is the one a workflow author can reason about.
- Changing `poll-interval` semantics or the number of requests per interval.

## Decisions

**One loop over the outstanding scans, one deadline.** Replace `wait_scan` with a loop that
walks the set of not-yet-terminal scans each pass, polls each one, records the elapsed time for
any that just finished, then sleeps `poll-interval` once per pass. The deadline is computed
once, before the pass loop starts, from the moment the first scan was started. The alternative,
threading a shared deadline through the existing `wait_scan`, is a smaller diff but keeps the
sequential ordering, so a hung first scan still hides a failed second one for the whole budget.

**Measure from the first `startRepositoryScan`, not from the start of the step.** The token
exchange and the repository and tool lookups are not scan time, and folding them into the
budget would make the timeout depend on gateway latency.

**Poll every outstanding scan on every pass.** Request volume goes from one per interval to one
per outstanding scan per interval. For the handful of tools an action run uses this is
negligible, and it is what makes early failure detection possible.

**Fail on the first terminal failure observed in a pass.** The pass finishes polling the scans
it has already reached before failing, so the log shows the transitions observed in that pass
rather than stopping mid-sweep.

**Report every unfinished scan on timeout.** With one deadline for the run, "still RUNNING, id
X" is no longer the whole story: the operator needs the ids of everything still outstanding to
open them in Vulnara.

## Risks / Trade-offs

- A workflow that relied on the per-scan budget to cover a slow multi-scanner run starts timing
  out → the timeout message names every outstanding scan, and the remediation is to raise
  `wait-timeout`, which now means what its name says. MAJOR bump, so `@v1` consumers are not
  affected until the tag moves.
- More GraphQL requests per interval on multi-tool runs → bounded by the number of tools, which
  is small, and each request is a single status field.
- The rewrite touches the part of the script that blocks the job → the existing polling tests
  cover the single-scan path unchanged, and the multi-scan behaviour gains its own tests.

## Migration Plan

Ships with the next major tag. Release notes carry the `BREAKING CHANGE` footer stating that
`wait-timeout` is now a run-wide budget and that multi-tool runs may need it raised. Rollback
is reverting the commit; no state, no persisted format.

## Open Questions

None.
