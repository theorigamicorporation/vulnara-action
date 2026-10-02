## Why

`resolve_repository` filters `repositories` on the last segment of `owner/name` and matches the
owner against `gitEntity.name`. vulnara-api stores an Azure DevOps repository as
`repositoryName = "{project}/{repo}"` under a git entity named after the Azure organization, so
the name filter never returns it and an Azure repository cannot be resolved. Refs OP#1198.

## What Changes

- An Azure DevOps repository is matched by `{org}/{project}/{repo}`, by `{project}/{repo}`, or by
  `{org}/{repo}` when the repository name is unique across the organization's projects.
- More than one Azure DevOps candidate fails the run as ambiguous and lists the candidates. No
  scan is started.
- Resolution for every other provider is unchanged: the existing owner match runs first and the
  Azure rule only applies to entities whose `gitType` is `azure_devops`.
- `docs/reference.md` and `docs/configuration.md` document the Azure forms of `repository`.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `scan-orchestration`: adds `Match Azure DevOps repositories by project`.

## Impact

- `entrypoint.sh` (`resolve_repository`): one extra `repositories` query, only when the owner
  match finds nothing.
- `test/orchestration_test.sh`: Azure match, Azure ambiguity and GitHub unchanged tests.
- No change to `action.yml`, inputs or outputs.
