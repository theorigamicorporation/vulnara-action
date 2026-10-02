## Why

Both resolver failures told the caller to open the Vulnara application and copy "the id shown
against the scanner". No screen in the application lists scanner ids, so the one instruction a
user gets when their `scan-tools` entry is rejected sent them nowhere. The `scan-tools` input
description in `action.yml` said the same.

## What Changes

- The non-id and unknown-id failures, and the `scan-tools` description, point at vulnara-cli's
  `vulnara docker_scan_tools` command and the `dockerScanTools { id categories }` query, the two
  places that actually list the ids. Neither returns a scanner's name.
- The test fixture's `categories` are upper case, as the gateway's `ScanCategory` enum serialises.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `scan-orchestration`: "Resolve the requested scan tools by id" names where the ids are listed.

## Impact

- `entrypoint.sh`, `action.yml`, `test/orchestration_test.sh`, `test/fixtures/base/dockerScanTools.json`,
  `README.md`, `docs/reference.md`.
- vulnara-site's `src/docs/data/action.json` snapshot copies the input description and is
  regenerated alongside.
