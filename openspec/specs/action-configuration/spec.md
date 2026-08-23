# Action Configuration

## Purpose
Defines how the action is declared to GitHub and how its inputs are read, defaulted and
validated before any network call is made. The action is a Docker container action whose
inputs GitHub exposes as `INPUT_*` environment variables with dashes preserved, so the
script must read them defensively. Every Vulnara endpoint has a production default that
can be overridden for non-prod environments, and invalid or missing configuration must
abort the run with a clear GitHub error annotation rather than a partial scan.

## Requirements

### Requirement: Declare the action interface
The system SHALL publish an `action.yml` that declares the action as a Docker container
action built from the repository `Dockerfile`, with the inputs `service-account`, `token`,
`tenant`, `scan-tools`, `branch`, `repository`, `git-token-id`, `fail-on`, `create-issue`,
`auto-remediate`, `wait-timeout`, `poll-interval`, `app-url`, `gateway-url`, `token-url`
and `oauth-client-id`, and the outputs `scan-result-ids`, `highest-severity` and `passed`.

#### Scenario: Action metadata is resolvable by GitHub
- **WHEN** a workflow references the action with `uses: theorigamicorporation/vulnara-action@v1`
- **THEN** `action.yml` declares `runs.using: docker` and `runs.image: Dockerfile`
- **AND** the container image installs `bash`, `curl`, `jq` and `ca-certificates` and sets
  `ENTRYPOINT ["/entrypoint.sh"]`

#### Scenario: Required inputs are marked required
- **WHEN** the action metadata is read
- **THEN** `service-account`, `token`, `tenant` and `scan-tools` are marked `required: true`
- **AND** every other input declares `required: false` together with a default value

### Requirement: Read dashed input environment variables
The system SHALL read each input from `INPUT_<UPPERCASE-NAME>` preserving dashes, and fall
back to the underscore form `INPUT_<UPPERCASE_NAME>` when the dashed variable is empty or
absent. Bash parameter expansion cannot address the dashed form, so `printenv` is used.

#### Scenario: Dashed variable is present
- **WHEN** the runner sets `INPUT_SERVICE-ACCOUNT=ci-bot`
- **THEN** the action resolves the `service-account` input to `ci-bot`

#### Scenario: Only the underscore variable is present
- **WHEN** `INPUT_SERVICE-ACCOUNT` is unset but `INPUT_SERVICE_ACCOUNT=ci-bot` is set
- **THEN** the action resolves the `service-account` input to `ci-bot`

### Requirement: Default optional inputs
The system SHALL default `branch` to the `GITHUB_REF_NAME` environment variable and
`repository` to `GITHUB_REPOSITORY` when the corresponding input is empty. It SHALL default
`fail-on` to `critical`, `create-issue` and `auto-remediate` to `false`, `wait-timeout` to
`1800`, `poll-interval` to `15`, and the `token-url`, `gateway-url`, `app-url` and
`oauth-client-id` endpoints to their production values. A trailing slash is stripped from
`app-url`.

#### Scenario: Branch and repository inferred from the workflow
- **WHEN** neither `branch` nor `repository` is supplied and the workflow runs with
  `GITHUB_REF_NAME=feature/x` and `GITHUB_REPOSITORY=acme/widgets`
- **THEN** the action scans branch `feature/x` of the Vulnara repository `acme/widgets`

#### Scenario: Non-prod endpoints overridden
- **WHEN** `gateway-url`, `token-url` and `app-url` are supplied
- **THEN** all GraphQL requests go to the supplied `gateway-url`, the token exchange goes to
  the supplied `token-url`, and scan links in the job summary are built from the supplied
  `app-url` with any trailing slash removed

### Requirement: Validate configuration before scanning
The system SHALL abort with a `::error::` annotation and a non-zero exit code when
`service-account`, `token`, `tenant` or `scan-tools` is empty, when the repository or branch
could not be determined, or when `fail-on` is not one of `none`, `low`, `medium`, `high`
or `critical`. The `fail-on` value is compared case-insensitively.

#### Scenario: Missing required input
- **WHEN** the `token` input is empty
- **THEN** the action emits `::error::token is required` and exits non-zero
- **AND** no request is sent to the token endpoint or the GraphQL gateway

#### Scenario: Branch cannot be determined
- **WHEN** the `branch` input is empty and `GITHUB_REF_NAME` is unset
- **THEN** the action fails with `branch could not be determined`

#### Scenario: Invalid fail-on value
- **WHEN** `fail-on` is set to `blocker`
- **THEN** the action fails with an error naming the accepted values
  `none|low|medium|high|critical`

#### Scenario: Uppercase fail-on value accepted
- **WHEN** `fail-on` is set to `HIGH`
- **THEN** the value is lowercased and the gate threshold is the `high` rank
