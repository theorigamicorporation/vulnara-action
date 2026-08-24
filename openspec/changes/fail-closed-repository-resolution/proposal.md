## Why

`resolve_repository` queries `repositories` filtered on `repositoryName` only, and the current
spec tells it to fall back to the first returned item when no candidate's `gitEntity.name`
matches the owner half of the `repository` input. When a tenant holds two repositories with the
same name under different owners and the owner match fails, the action silently resolves,
scans and gates on the wrong repository, then prints that repository's own full name as if it
were the requested one. A security gate that scans something other than what CI asked for is
worse than a gate that stops, so the resolution should fail closed.

## What Changes

- **BREAKING**: when the `repositories` query returns items but none has a `gitEntity.name`
  matching the owner half of `repository` case-insensitively, the action fails instead of
  falling back to the first item.
- The failure message names the requested `owner/name`, the tenant, and the owners that were
  actually returned, so the operator can see whether the git entity is recorded in Vulnara
  under a different name.
- A single returned item that does not match the owner is still a failure. Guessing from a
  result set of one is the same guess, just with better odds.
- The reported repository full name keeps coming from the resolved Vulnara entity, which is now
  guaranteed to match the requested owner.

Consumers pinned to `v1` are unaffected until the major tag moves. Anyone relying on the
fallback (an entity whose Vulnara name differs from the git owner) has to rename the entity in
Vulnara to match, and that is the point: the mismatch was never visible before.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `scan-orchestration`: `Resolve the repository in Vulnara` drops the fall back to the first
  returned item and gains a scenario for the ambiguous / non-matching owner case.

## Impact

- `entrypoint.sh:114-141` (`resolve_repository`), the `// (.repositories.items[0])` fallback.
- `test/orchestration_test.sh`: `test_repository_falls_back_to_the_first_item_when_no_owner_matches`
  is replaced by a failure test, and the `cloneUrl` / `programmingLanguage` assertions it also
  carried move to a fixture whose owner matches.
- `docs/troubleshooting.md`: the "The wrong repository is scanned" known issue is removed and a
  common failure entry for the new message replaces it.
- No change to `action.yml`, inputs, outputs or the job summary.
