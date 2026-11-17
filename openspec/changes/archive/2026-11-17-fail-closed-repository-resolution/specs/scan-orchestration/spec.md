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

### Requirement: Match Azure DevOps repositories by project
The system SHALL resolve an Azure DevOps repository from its project and name when no item
from the `repositoryName` query has a `gitEntity.name` matching the owner. It SHALL then query
`repositories` with `search` set to the last segment of the `repository` input and consider
only items whose `gitEntity.gitType` is `azure_devops`. An item SHALL match
when its `repositoryName` equals the input with the first segment removed and its
`gitEntity.name` equals that first segment case-insensitively (`{org}/{project}/{repo}`), when
its `repositoryName` equals the whole input (`{project}/{repo}`), or when its `gitEntity.name`
equals the first segment case-insensitively and the last segment of its `repositoryName` equals
the last segment of the input (`{org}/{repo}`). Exactly one match SHALL be resolved. More
than one match SHALL fail the run. Items of any other `gitType` SHALL NOT be matched by this rule.

#### Scenario: Azure repository matched by organization, project and name
- **WHEN** `repository` is `acme/web/widgets` and Vulnara holds `web/widgets` under the
  `azure_devops` entity `acme`
- **THEN** that repository is resolved and reported as `acme/web/widgets`

#### Scenario: Azure repository matched by project and name
- **WHEN** `repository` is `web/widgets` and Vulnara holds `web/widgets` under a single
  `azure_devops` entity
- **THEN** that repository is resolved

#### Scenario: Same repository name in two Azure projects
- **WHEN** `repository` is `acme/widgets` and the `azure_devops` entity `acme` holds both
  `web/widgets` and `api/widgets`
- **THEN** the action fails with a message stating `acme/widgets` is ambiguous in the tenant and
  listing both candidates
- **AND** no scan is started

#### Scenario: Other providers are not matched by the Azure rule
- **WHEN** the owner match finds nothing and the search returns only items whose `gitType` is
  not `azure_devops`
- **THEN** no Azure DevOps item is resolved, and the run fails as described in `Resolve the
  repository in Vulnara`
