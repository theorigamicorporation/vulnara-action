# Tests

Offline tests for `entrypoint.sh`. They never touch the network: `curl` and
`sleep` are replaced by the stubs in `test/stubs`, and every response comes from
a JSON fixture. There is no test framework to install; the suite is plain bash
and needs only `bash` and `jq`.

## Running

```bash
./test/run-tests.sh              # everything
./test/run-tests.sh config       # one file (test/config_test.sh)
./test/run-tests.sh -f gate      # only tests whose name contains "gate"
```

The runner exits non-zero if any test fails.

## Layout

```
test/run-tests.sh        discovers and runs every test_* function
test/lib/harness.sh      assertions, workspace setup, the action runner
test/stubs/curl          fake curl: records requests, replies from fixtures
test/stubs/sleep         fake sleep: records the delay, returns immediately
test/fixtures/base/*     default API responses, copied per test
test/config_test.sh      action-configuration spec
test/orchestration_test.sh  scan-orchestration spec
test/reporting_test.sh   findings-gate-reporting spec
```

Each test is named after the OpenSpec requirement and scenario it covers and
carries a `# spec:` comment pointing at `openspec/specs/<capability>/spec.md`.

## Writing a test

Define a `test_*` function in one of the `*_test.sh` files. The harness has
already created a temp workspace, copied the base fixtures and set the default
inputs, so a test only overrides what it cares about:

```bash
test_example() {
  env_set "INPUT_FAIL-ON" "high"       # inputs are injected with env(1)
  fixture scanFindings.json <<'J'      # override a canned response
{"data":{"scanFindings":{"items":[]}}}
J
  run_action                           # sets OUT, ERR, STATUS
  assert_success
  assert_contains "$ERR" "scan gate passed" "gate verdict"
}
```

Responses can be sequenced per call: `scanResult.1.json` answers the first
poll, `scanResult.2.json` the second, and `scanResult.json` every call after
that.

Fixtures contain no real credentials, hosts or tenant data. Keep it that way:
use `example.test` hostnames and obviously fake ids.
