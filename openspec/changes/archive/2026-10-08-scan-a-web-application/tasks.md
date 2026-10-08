## 1. Tests

- [x] 1.1 Teach the curl stub the web operations (`scanCategories`, `webTargets`, `webTarget`,
      `createWebTarget`, `startWebScan`, `webScanResult`, the two finding queries).
- [x] 1.2 Add `test/web_test.sh`: validation (consent, both inputs, credentials, bad id,
      neither scan-tools nor web input), web-only run, combined run, reuse vs register,
      ambiguous match, scanning not enabled (pre-check and start refusal), limit, address
      refused, not found, failed scan, timeout, gate, outputs, summary, no scanner name.

## 2. Implementation

- [x] 2.1 Declare the inputs and outputs in `action.yml`; relax `scan-tools` to optional.
- [x] 2.2 Validate the web inputs before the first network call.
- [x] 2.3 Availability check, target resolution or registration, start, wait.
- [x] 2.4 Count web findings, feed the gate and outputs, render the summary section.
- [x] 2.5 `shellcheck -S warning` and `./test/run-tests.sh` clean.

## 3. Documentation

- [x] 3.1 README, `docs/configuration.md`, `docs/reference.md`, `docs/architecture.md`,
      `docs/troubleshooting.md`, the example workflow and `openspec/project.md`.
