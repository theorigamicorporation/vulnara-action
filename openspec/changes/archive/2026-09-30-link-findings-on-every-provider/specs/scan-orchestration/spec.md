## ADDED Requirements

### Requirement: Build a browsing URL for every provider
The system SHALL build the Azure DevOps browsing URL as `<htmlUrl>/<project>/_git/<repo>`
from a `repositoryName` of the form `<project>/<repo>`, and SHALL strip any credentials from
the `cloneUrl` before using it as the browsing URL fallback.

#### Scenario: Azure DevOps repository
- **WHEN** the resolved repository has `gitType` `azure_devops`, an `htmlUrl` and a
  `repositoryName` of `<project>/<repo>`
- **THEN** the browsing URL is `<htmlUrl>/<project>/_git/<repo>`

#### Scenario: Clone URL carries credentials
- **WHEN** no `htmlUrl` is available and the `cloneUrl` contains `user:secret@` userinfo
- **THEN** the browsing URL is the `cloneUrl` without the userinfo and without a trailing `.git`
