## 1. Tests

- [x] 1.1 Replace the `scanner_display` unit tests with `category_display` and
      `categories_display` tests covering the four labels, the `Uncategorised` fallback, and the
      deduplicating join.
- [x] 1.2 Add a test asserting the action source carries no codename and no `scanner_display`.
- [x] 1.3 Retarget the orchestration and reporting assertions from codenames to category labels.
- [x] 1.4 Add a test that a gateway without `DockerScanTool.categories` still resolves and scans.
- [x] 1.5 Add a test that a gateway without `DockerScanTool.name` still resolves a pinned id.
- [x] 1.6 Add a test that a name against such a gateway fails with an accurate message.
- [x] 1.7 Add a test that a non-field GraphQL error on the catalogue still aborts the run.
- [x] 1.8 Revert each fix in turn and confirm the new tests fail for the right reason.

## 2. Implementation

- [x] 2.1 Split `gql` into `gql_post` and `gql`.
- [x] 2.2 Replace `scanner_display` with `category_display` and `categories_display`.
- [x] 2.3 Add `scan_tool_catalogue`, narrowing the selection set from the validation error.
- [x] 2.4 Match on id first in `resolve_tools`, emit a category label, and branch the failure
      message on whether names still resolve.
- [x] 2.5 Rename the label arrays and the two summary column headers to `Category`.
- [x] 2.6 `shellcheck -S warning` and `./test/run-tests.sh` clean.

## 3. Documentation

- [x] 3.1 Rewrite the Scanners section of `docs/reference.md` around categories and the adaptive
      selection set.
- [x] 3.2 Correct step 3 of `docs/architecture.md`.
- [x] 3.3 Correct the scan tool entry in `openspec/project.md`.
- [x] 3.4 Correct the `scan-tools` row in `README.md` and `docs/configuration.md`.

## 4. Validate

- [x] 4.1 `just ci` green.
- [x] 4.2 `openspec validate --specs --strict` green after the archive.
