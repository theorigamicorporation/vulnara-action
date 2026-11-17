## Why

The gateway is gaining neutral names for the scan tool catalogue: `scanTools` and `scanTool(id)`
alongside `dockerScanTools` and `dockerScanTool`, and `StartRepositoryScanInput.scanToolId`
alongside `dockerScanToolId`. The old names keep working and are deprecated. What a customer reads
should point at the names that stay, and should not name a private repository: the failure hint and
the `scan-tools` description named the CLI by its repository rather than as the Vulnara CLI.

## What Changes

- The non-id and unknown-id failures, the `scan-tools` input description, `README.md` and
  `docs/reference.md` point at the `scanTools { id categories }` query and at the Vulnara CLI's
  `vulnara docker_scan_tools` command.
- The requests the action sends are unchanged. They keep using `dockerScanTools` and
  `dockerScanToolId` until every gateway the action is pointed at serves the new names, so a pinned
  `v1` keeps working against the gateway that is deployed today.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `scan-orchestration`: "Resolve the requested scan tools by id" names the `scanTools` query and the
  Vulnara CLI where it points the caller at the ids.

## Impact

- `entrypoint.sh` (the hint text only), `action.yml`, `README.md`, `docs/reference.md`,
  `docs/architecture.md`, `openspec/project.md`, `test/orchestration_test.sh`.
- No change to inputs, outputs, the gate or any request body.
