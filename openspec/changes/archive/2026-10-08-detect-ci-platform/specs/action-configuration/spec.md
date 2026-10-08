## MODIFIED Requirements

### Requirement: Declare the action interface
The system SHALL publish an `action.yml` that declares the action as a Docker container
action built from the repository `Dockerfile`, with the inputs `service-account`, `token`,
`tenant`, `scan-tools`, `branch`, `repository`, `git-token-id`, `fail-on`, `create-issue`,
`auto-remediate`, `wait-timeout`, `poll-interval`, `app-url`, `gateway-url`, `token-url`,
`oauth-client-id`, `web-target-id`, `web-url`, `web-ownership-consent`, `ci-platform` and
`report-dir`, and the outputs `scan-result-ids`, `highest-severity`, `passed`, `web-target-id`
and `web-scan-result-id`.

#### Scenario: Action metadata is resolvable by GitHub
- **WHEN** a workflow references the action with `uses: theorigamicorporation/vulnara-action@v1`
- **THEN** `action.yml` declares `runs.using: docker` and `runs.image: Dockerfile`
- **AND** the container image installs `bash`, `curl`, `jq`, `tar` and `ca-certificates` and
  sets `ENTRYPOINT ["/entrypoint.sh"]`

#### Scenario: Required inputs are marked required
- **WHEN** the action metadata is read
- **THEN** `service-account`, `token` and `tenant` are marked `required: true`
- **AND** every other input, `scan-tools` included, declares `required: false` together with a
  default value, because a run may scan a repository, a web target, or both

#### Scenario: Platform inputs default to detection
- **WHEN** the action metadata is read
- **THEN** `ci-platform` and `report-dir` declare `required: false` with an empty default, which
  means "detect" and "the platform default" respectively

### Requirement: Default optional inputs
The system SHALL default `branch` and `repository` from the detected CI platform when the
corresponding input is empty, as the `ci-platform` capability specifies. It SHALL default
`fail-on` to `critical`, `create-issue` and `auto-remediate` to `false`, `git-token-id` to
the empty string, `wait-timeout` to `1800`, `poll-interval` to `15`, and the `token-url`,
`gateway-url`, `app-url` and `oauth-client-id` endpoints to their production values. A
trailing slash is stripped from `app-url`.

#### Scenario: Branch and repository inferred from the workflow
- **WHEN** neither `branch` nor `repository` is supplied and the workflow runs on GitHub with
  `GITHUB_REF_NAME=feature/x` and `GITHUB_REPOSITORY=acme/widgets`
- **THEN** the action scans branch `feature/x` of the Vulnara repository `acme/widgets`

#### Scenario: Non-prod endpoints overridden
- **WHEN** `gateway-url`, `token-url` and `app-url` are supplied
- **THEN** all GraphQL requests go to the supplied `gateway-url`, the token exchange goes to
  the supplied `token-url`, and scan links in the job summary are built from the supplied
  `app-url` with any trailing slash removed

#### Scenario: git-token-id left unset
- **WHEN** `git-token-id` is not supplied
- **THEN** it resolves to the empty string, which is the value the rest of the run treats as
  "no git token was chosen"
