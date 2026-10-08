## MODIFIED Requirements

### Requirement: Declare the action interface
The system SHALL publish an `action.yml` that declares the action as a Docker container
action built from the repository `Dockerfile`, with the inputs `service-account`, `token`,
`tenant`, `scan-tools`, `branch`, `repository`, `git-token-id`, `fail-on`, `create-issue`,
`auto-remediate`, `wait-timeout`, `poll-interval`, `app-url`, `gateway-url`, `token-url`,
`oauth-client-id`, `web-target-id`, `web-url` and `web-ownership-consent`, and the outputs
`scan-result-ids`, `highest-severity`, `passed`, `web-target-id` and `web-scan-result-id`.

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

### Requirement: Validate configuration before scanning
The system SHALL abort with a `::error::` annotation and a non-zero exit code when
`service-account`, `token` or `tenant` is empty, when `scan-tools` is empty and no web input is
set, when `scan-tools` is set and the repository or branch could not be determined, or when
`fail-on` is not one of `none`, `low`, `medium`, `high` or `critical`. The `fail-on` value is
compared case-insensitively.

#### Scenario: Missing required input
- **WHEN** the `token` input is empty
- **THEN** the action emits `::error::token is required` and exits non-zero
- **AND** no request is sent to the token endpoint or the GraphQL gateway

#### Scenario: Nothing to scan
- **WHEN** `scan-tools`, `web-target-id` and `web-url` are all empty
- **THEN** the action emits `::error::scan-tools is required` and exits non-zero

#### Scenario: Branch cannot be determined
- **WHEN** `scan-tools` is set, the `branch` input is empty and `GITHUB_REF_NAME` is unset
- **THEN** the action fails with `branch could not be determined`

#### Scenario: Web-only run needs no repository
- **WHEN** `scan-tools` is empty, `web-target-id` is set and neither `repository` nor
  `GITHUB_REPOSITORY` is available
- **THEN** the run is not rejected for the missing repository or branch

#### Scenario: Invalid fail-on value
- **WHEN** `fail-on` is set to `blocker`
- **THEN** the action fails with an error naming the accepted values
  `none|low|medium|high|critical`

#### Scenario: Uppercase fail-on value accepted
- **WHEN** `fail-on` is set to `HIGH`
- **THEN** the value is lowercased and the gate threshold is the `high` rank

## ADDED Requirements

### Requirement: Validate the web application inputs
The system SHALL validate the web inputs before the first network call. `web-target-id` and
`web-url` SHALL NOT both be set. `web-target-id` SHALL be an id. `web-url` SHALL be an `http`
or `https` URL without credentials, and SHALL be refused unless `web-ownership-consent` is
exactly the lowercase string `true`, because using it may register the URL as a scan target,
which is an attestation that the caller owns or is authorised to scan it. A URL carrying
credentials SHALL NOT be echoed in the failure.

#### Scenario: web-url without consent
- **WHEN** `web-url` is set and `web-ownership-consent` is empty, `false`, `TRUE` or `yes`
- **THEN** the action fails naming `web-ownership-consent: true` as the requirement
- **AND** no request is sent to the token endpoint or the GraphQL gateway

#### Scenario: Both web inputs
- **WHEN** `web-target-id` and `web-url` are both set
- **THEN** the action fails saying only one may be set, before any network call

#### Scenario: URL with credentials
- **WHEN** `web-url` is `https://user:secret@app.example.com`
- **THEN** the action fails saying the URL must not carry credentials
- **AND** the secret does not appear in the log

#### Scenario: web-target-id needs no consent
- **WHEN** `web-target-id` is set and `web-ownership-consent` is not
- **THEN** the run is not rejected for the missing consent
