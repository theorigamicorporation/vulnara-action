## 1. Tests

- [ ] 1.1 Add a multi-tool timeout test to `test/orchestration_test.sh` proving the deadline is
      shared: two tools, a `wait-timeout` that only one scan could fit in, and an assertion
      that the run fails once rather than granting each scan its own budget.
- [ ] 1.2 Add a test proving a `FAILED` second scan fails the run while the first scan is still
      polling, rather than after it completes.
- [ ] 1.3 Extend the timeout test to assert every outstanding scan is named in the message.
- [ ] 1.4 Confirm the existing single-scan polling, transition-logging and duration tests still
      describe the intended behaviour, and run `./test/run-tests.sh` to watch the new tests
      fail for the right reason.

## 2. Implementation

- [ ] 2.1 Record the run-wide deadline once, when the first `startRepositoryScan` returns.
- [ ] 2.2 Replace the per-scan `wait_scan` calls with a single loop that polls every
      outstanding scan per pass and sleeps `poll-interval` once per pass.
- [ ] 2.3 Keep per-scan start times so durations and transition logs are unchanged.
- [ ] 2.4 Fail immediately on the first `FAILED` or `CANCELLED` observed.
- [ ] 2.5 Emit the timeout failure listing every outstanding scan with its last status and id.
- [ ] 2.6 Run `./test/run-tests.sh` and `shellcheck -S warning entrypoint.sh` clean.

## 3. Documentation

- [ ] 3.1 Remove the "A multi-scanner run takes far longer than `wait-timeout`" known issue
      from `docs/troubleshooting.md` and update the timeout entry under common failures.
- [ ] 3.2 Update the `wait-timeout` description in `action.yml`, `docs/configuration.md` and
      `README.md` to say it bounds the whole waiting phase.
- [ ] 3.3 Update the blocking-behaviour note in `openspec/project.md` and
      `docs/architecture.md`.
- [ ] 3.4 Commit with a `BREAKING CHANGE:` footer explaining the new meaning of `wait-timeout`.
