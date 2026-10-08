## ADDED Requirements

### Requirement: Match repositories under nested namespaces
The system SHALL match the owner of a non-Azure repository against everything before the last
`/` of the `repository` input, not only its first segment, so that a GitLab project in a
subgroup resolves against the git entity Vulnara stores under the subgroup path. The comparison
SHALL be case-insensitive. A two-segment `owner/name` input SHALL resolve exactly as before.
This rule SHALL NOT change how Azure DevOps repositories are matched.

#### Scenario: GitLab project in a subgroup
- **WHEN** `repository` is `acme/platform/widgets` and Vulnara holds `widgets` under the
  `gitlab` entity `acme/platform`
- **THEN** that repository is resolved and reported as `acme/platform/widgets`

#### Scenario: Same project name in a parent group
- **WHEN** `repository` is `acme/platform/widgets` and Vulnara holds `widgets` under both the
  `gitlab` entities `acme` and `acme/platform`
- **THEN** the repository under `acme/platform` is resolved

#### Scenario: Two-segment input unchanged
- **WHEN** `repository` is `acme/widgets` and Vulnara holds `widgets` under the `github`
  entity `acme`
- **THEN** that repository is resolved, as before this requirement

### Requirement: Prefer the platform's provider when resolving the repository
The system SHALL, when the CI platform is `github` or `gitlab` and more than one non-Azure
candidate matches the requested owner and name, take the candidate whose `gitEntity.gitType`
equals the platform's provider (`github` for `github`, `gitlab` for `gitlab`). When no matching
candidate has that provider, or the platform is `none`, resolution SHALL proceed as before this
requirement.

#### Scenario: Same repository on GitHub and GitLab in one tenant
- **WHEN** the platform is `gitlab`, `repository` is `acme/widgets`, and Vulnara holds `widgets`
  under both the `github` entity `acme` and the `gitlab` entity `acme`
- **THEN** the `gitlab` repository is resolved and the summary reports provider `gitlab`

#### Scenario: Only another provider matches
- **WHEN** the platform is `gitlab`, `repository` is `acme/widgets`, and Vulnara holds `widgets`
  only under the `github` entity `acme`
- **THEN** that repository is resolved, as before this requirement

#### Scenario: GitHub run with a GitLab twin
- **WHEN** the platform is `github` and Vulnara holds `acme/widgets` under both a `gitlab` and a
  `github` entity named `acme`
- **THEN** the `github` repository is resolved
