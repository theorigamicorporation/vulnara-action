## ADDED Requirements

### Requirement: Coerce boolean inputs by exact match
The system SHALL treat `create-issue` and `auto-remediate` as true only when the
input is exactly the lowercase string `true`; every other value, including
`TRUE`, `True`, `yes`, `1`, `on` and any empty or unset input, SHALL be sent to
the gateway as `false`. The comparison is not case-insensitive and no warning is
emitted for a value that was clearly meant to be affirmative.

The system SHALL NOT reject `auto-remediate: true` when `create-issue` is false.
`action.yml` describes `auto-remediate` as requiring `create-issue`, but no
check enforces it, so the mutation input carries `createIssue: false` together
with `autoRemediate: true` and the outcome is whatever the platform makes of
that combination. This records the behaviour as it stands; enforcing the
documented dependency would change what such a workflow does today and is a
separate change.

#### Scenario: Lowercase true
- **WHEN** `create-issue: 'true'` is supplied
- **THEN** the scan mutation input carries `createIssue: true`

#### Scenario: Affirmative value that is not the literal string
- **WHEN** `create-issue: 'TRUE'` or `create-issue: 'yes'` is supplied
- **THEN** the mutation input carries `createIssue: false` and no warning is emitted

#### Scenario: Input omitted
- **WHEN** neither boolean input is supplied
- **THEN** both flags default to `false` and the mutation input carries `createIssue: false` and `autoRemediate: false`

#### Scenario: auto-remediate without create-issue
- **WHEN** `auto-remediate: 'true'` is supplied and `create-issue` is left at its default
- **THEN** the run is not rejected and the mutation input carries `createIssue: false` together with `autoRemediate: true`

## MODIFIED Requirements

### Requirement: Declare the action interface
The system SHALL publish an `action.yml` that declares the action as a Docker container
action built from the repository `Dockerfile`, with the inputs `service-account`, `token`,
`tenant`, `scan-tools`, `branch`, `repository`, `git-token-id`, `fail-on`, `create-issue`,
`auto-remediate`, `wait-timeout`, `poll-interval`, `app-url`, `gateway-url`, `token-url`
and `oauth-client-id`, and the outputs `scan-result-ids`, `highest-severity` and `passed`.

#### Scenario: Action metadata is resolvable by GitHub
- **WHEN** a workflow references the action with `uses: theorigamicorporation/vulnara-action@v1`
- **THEN** `action.yml` declares `runs.using: docker` and `runs.image: Dockerfile`
- **AND** the container image installs `bash`, `curl`, `jq`, `tar` and `ca-certificates` and
  sets `ENTRYPOINT ["/entrypoint.sh"]`

#### Scenario: Required inputs are marked required
- **WHEN** the action metadata is read
- **THEN** `service-account`, `token`, `tenant` and `scan-tools` are marked `required: true`
- **AND** every other input declares `required: false` together with a default value

### Requirement: Default optional inputs
The system SHALL default `branch` to the `GITHUB_REF_NAME` environment variable and
`repository` to `GITHUB_REPOSITORY` when the corresponding input is empty. It SHALL default
`fail-on` to `critical`, `create-issue` and `auto-remediate` to `false`, `git-token-id` to
the empty string, `wait-timeout` to `1800`, `poll-interval` to `15`, and the `token-url`,
`gateway-url`, `app-url` and `oauth-client-id` endpoints to their production values. A
trailing slash is stripped from `app-url`.

#### Scenario: Branch and repository inferred from the workflow
- **WHEN** neither `branch` nor `repository` is supplied and the workflow runs with
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
