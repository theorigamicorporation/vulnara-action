## MODIFIED Requirements

### Requirement: Resolve the repository in Vulnara
The system SHALL query `repositories` filtered by `repositoryName` equal to the name part of
the `owner/name` repository input, and select the item whose `gitEntity.name` matches the owner
case-insensitively. It SHALL NOT fall back to another item when no `gitEntity.name` matches the
owner. It SHALL record the repository id, full name, provider (`gitType`), visibility, enabled
flag, programming languages and browsing URL.

#### Scenario: Repository resolved and reported
- **WHEN** the query returns a repository whose `gitEntity.name` matches the owner
- **THEN** the action logs the repository full name, Vulnara id, provider, visibility,
  branch, languages and enabled state
- **AND** the browsing URL is built from `gitEntity.htmlUrl` plus the repository name, or
  from `cloneUrl` with a trailing `.git` stripped when no `htmlUrl` is available

#### Scenario: Repository not present in Vulnara
- **WHEN** the query returns no items
- **THEN** the action fails with a message stating the repository was not found in Vulnara
  for the tenant and that it must be added first

#### Scenario: No returned repository belongs to the requested owner
- **WHEN** the query returns one or more items and none has a `gitEntity.name` equal to the
  owner case-insensitively
- **THEN** the action fails with a message naming the requested `owner/name` and the tenant,
  and listing the `gitEntity.name` of every returned item
- **AND** no scan is started

#### Scenario: Repository is disabled
- **WHEN** the resolved repository has `enabled: false`
- **THEN** the action emits a `::warning::` that the repository is disabled and the scan will
  likely be rejected, and continues

#### Scenario: Private repository without a git token
- **WHEN** the resolved repository is private and `git-token-id` is empty
- **THEN** the action emits a `::warning::` that cloning may fail, and continues
