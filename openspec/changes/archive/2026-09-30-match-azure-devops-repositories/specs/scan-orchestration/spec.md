## ADDED Requirements

### Requirement: Match Azure DevOps repositories by project
The system SHALL resolve an Azure DevOps repository from its project and name when no item
from the `repositoryName` query has a `gitEntity.name` matching the owner. It SHALL then query
`repositories` with `search` set to the last segment of the `repository` input and consider
only items whose `gitEntity.gitType` is `azure_devops`. An item SHALL match
when its `repositoryName` equals the input with the first segment removed and its
`gitEntity.name` equals that first segment case-insensitively (`{org}/{project}/{repo}`), when
its `repositoryName` equals the whole input (`{project}/{repo}`), or when its `gitEntity.name`
equals the first segment case-insensitively and the last segment of its `repositoryName` equals
the last segment of the input (`{org}/{repo}`). Exactly one match SHALL be resolved and SHALL
take precedence over the fall back to the first returned item. More than one match SHALL fail
the run. Items of any other `gitType` SHALL NOT be matched by this rule.

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
- **THEN** resolution behaves as it did before this requirement
