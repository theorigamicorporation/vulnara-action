## Why

DAST is becoming a platform category (OpenProject #1292, part of the DAST beta under #778):
`dast`, labelled "Web application". `category_display` fails closed, so until it knows the value
a scan covering it is logged and summarised as `Uncategorised`. Naming it before any scanner
serves it means the first such scan is labelled correctly.

## What Changes

- `category_display` maps `dast` (any casing; the gateway serialises `DAST`) to
  `Web application`.
- The tests that used `dast` as the example of an unknown category use `iac` instead, so the
  `Uncategorised` fallback stays covered.
- `docs/reference.md` and `openspec/project.md` list the category.

No scanner serves `dast` yet, so no run prints the label today. Purely additive.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `scan-orchestration`: `dast` is a known category, labelled `Web application`.

## Impact

`entrypoint.sh`, `test/config_test.sh`, `docs/reference.md`, `openspec/project.md`. No input,
output or gateway query changes.
