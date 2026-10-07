## 1. Verify the shipped behaviour

- [x] 1.1 Confirm `fail()` exits the process and that `resolve_tools` is captured into a variable
- [x] 1.2 Confirm neither the service-account password nor the JWT is written to `GITHUB_OUTPUT`, the job summary or any log line
- [x] 1.3 Confirm `create-issue` and `auto-remediate` are compared against the literal string `true`
- [x] 1.4 Confirm nothing rejects `auto-remediate` without `create-issue`
- [x] 1.5 Confirm `tar` is installed in the image and `git-token-id` is a declared optional input

## 2. Write the requirements

- [x] 2.1 Add the `runtime-safety` capability with the fail-closed and credential requirements
- [x] 2.2 Add the boolean coercion requirement, including the unenforced dependency
- [x] 2.3 Correct the interface requirement to list `tar`
- [x] 2.4 Correct the defaults requirement to include `git-token-id`, carrying every existing scenario forward

## 3. Validate

- [x] 3.1 `openspec validate document-safety-invariants --strict` passes
- [x] 3.2 `openspec validate --all --strict` reports 0 failed
- [x] 3.3 The two in-flight changes are untouched
