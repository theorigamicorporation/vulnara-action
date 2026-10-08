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

