## Why

The action starts every scan up front but waits for them one at a time, and `wait_scan`
computes a fresh start time and deadline from `wait-timeout` on each call. `wait-timeout` is
therefore a per-scan budget, not a budget for the step, and the worst case is the number of
tools multiplied by the timeout: at the default 1800s, a four-scanner run can block a job for
roughly two hours. A CI gate has to be bounded by something the workflow author set, and today
the only such bound is the job's own `timeout-minutes`, which kills the step without a
diagnosis.

Sequential waiting also delays what the job most wants to know. A scan that fails first is not
reported until every scan queued ahead of it has finished, so a run can spend its whole budget
waiting for scans whose result no longer matters.

## What Changes

- **BREAKING**: `wait-timeout` becomes the budget for the whole waiting phase, measured from
  the moment the first scan is started, instead of a fresh budget per scan.
- Every started scan is polled in one loop against that single deadline, so a scan that reaches
  `FAILED` or `CANCELLED` fails the run as soon as it is observed rather than after the scans
  ahead of it finish.
- The timeout failure names every scan that had not reached a terminal status when the deadline
  passed, with its last observed status and scan result id, rather than only the one being
  waited on.
- Per-scan elapsed durations, status transition logging and the job summary keep their current
  shape.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `scan-orchestration`: `Wait for scans to finish` replaces the per-scan deadline with a single
  run-wide deadline and gains a scenario for a multi-scan timeout.

## Impact

- `entrypoint.sh:189-205` (`wait_scan`) and the sequential await loop that calls it.
- `test/orchestration_test.sh`: the timeout test gains a multi-tool case; the per-scan polling
  tests are unaffected because a single-tool run behaves identically.
- `docs/troubleshooting.md`: the "A multi-scanner run takes far longer than `wait-timeout`"
  known issue is removed; `docs/configuration.md` and `README.md` describe `wait-timeout` as
  per run.
- `action.yml`: the `wait-timeout` description only, no new or removed input.
