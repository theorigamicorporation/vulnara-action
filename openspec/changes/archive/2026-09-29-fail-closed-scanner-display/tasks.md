## 1. Tests

- [x] 1.1 Invert the unmapped-name assertion in `test/config_test.sh` so `scanner_display`
      returns `Unknown scanner` rather than the stored name.
- [x] 1.2 Replace `test_unknown_tool_reports_the_available_list` in
      `test/orchestration_test.sh` with a test asserting the failure names the rejected entry
      and the tenant, points at the app URL, and contains no stored tool name.
- [x] 1.3 Add a test that a resolved tool whose stored name is not mapped appears as
      `Unknown scanner` and that its stored name is in no log line or summary line.
- [x] 1.4 Update the `tool` info assertions to expect display names.
- [x] 1.5 Run `./test/run-tests.sh` and confirm the new tests fail for the right reason.

## 2. Implementation

- [x] 2.1 Change the `scanner_display` fallback arm to `Unknown scanner`.
- [x] 2.2 Rewrite the `resolve_tools` failure message: rejected entry, tenant, app URL, no
      roster.
- [x] 2.3 Have `resolve_tools` emit `id<TAB>display name` so the stored name does not leave it.
- [x] 2.4 Rename the caller's array and print the display name on the `tool` line.
- [x] 2.5 `shellcheck -S warning` and `./test/run-tests.sh` clean.

## 3. Documentation

- [x] 3.1 Remove the mapping table from `docs/reference.md` and rewrite the section around it.
- [x] 3.2 Correct `docs/architecture.md` step 3, which promises the available list.
- [x] 3.3 Drop the roster and the codenames from `openspec/project.md`.
- [x] 3.4 Drop the roster from the `scan-tools` description in `action.yml`.

## 4. Validate

- [x] 4.1 `just ci` green.
- [x] 4.2 `openspec validate --specs --strict` green after the archive.
