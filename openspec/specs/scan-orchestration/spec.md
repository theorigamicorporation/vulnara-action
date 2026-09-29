# Scan Orchestration

## Purpose
Covers everything the action does against the Vulnara platform: exchanging the service
account for a short-lived JWT, resolving the target repository and the requested scan tools,
starting one scan per tool on the branch, and waiting for every scan to reach a terminal
state. This is the core of the action and the part that blocks the CI job, so it must handle
token expiry, GraphQL errors, unknown repositories or tools, failed scans and timeouts
explicitly.
## Requirements
### Requirement: Authenticate the service account
The system SHALL obtain a JWT from the OAuth token endpoint using the
`client_credentials` grant with `client_id` set to the `oauth-client-id` input, `username`
set to `service-account`, `password` set to `token` and `scope=profile`. It SHALL cache the
token and refresh it when fewer than 120 seconds remain of its `expires_in` lifetime,
defaulting to 3600 seconds when the response omits `expires_in`.

#### Scenario: Successful token exchange
- **WHEN** the token endpoint returns a body containing `access_token`
- **THEN** the action logs that it authenticated as the service account for the tenant and
  reports the approximate token lifetime
- **AND** subsequent GraphQL requests send `Authorization: Bearer <access_token>`

#### Scenario: Token refreshed during a long scan
- **WHEN** a scan is still running and the cached token is within 120 seconds of expiring
- **THEN** the action performs a new `client_credentials` exchange before the next request
  instead of failing the job

#### Scenario: Invalid credentials
- **WHEN** the token endpoint response contains no `access_token`
- **THEN** the action prints the `error_description` or `error` from the response and fails
  with `could not authenticate the service account (check service-account/token/tenant)`

### Requirement: Send tenant-scoped GraphQL requests
The system SHALL send every GraphQL request to the `gateway-url` as a JSON POST carrying the
`Authorization: Bearer` header and an `X-Tenant` header set to the `tenant` input, and SHALL
build all request bodies with `jq -n` so input values are JSON-encoded.

#### Scenario: GraphQL returns errors
- **WHEN** a GraphQL response contains an `errors` array
- **THEN** the action prints each error as `<extensions.code>: <message>` and fails with
  `GraphQL request failed`

#### Scenario: GraphQL succeeds
- **WHEN** a GraphQL response contains no `errors`
- **THEN** only the `data` object is passed on to the caller

### Requirement: Resolve the repository in Vulnara
The system SHALL query `repositories` filtered by `repositoryName` equal to the name part of
the `owner/name` repository input, and select the item whose `gitEntity.name` matches the
owner case-insensitively, falling back to the first returned item. It SHALL record the
repository id, full name, provider (`gitType`), visibility, enabled flag, programming
languages and browsing URL.

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

#### Scenario: Repository is disabled
- **WHEN** the resolved repository has `enabled: false`
- **THEN** the action emits a `::warning::` that the repository is disabled and the scan will
  likely be rejected, and continues

#### Scenario: Private repository without a git token
- **WHEN** the resolved repository is private and `git-token-id` is empty
- **THEN** the action emits a `::warning::` that cloning may fail, and continues

### Requirement: Resolve the requested scan tools
The system SHALL split the `scan-tools` input on commas, trim surrounding whitespace from each
entry, and match each entry against the `dockerScanTools` list by exact id, and additionally by
case-insensitive name while the gateway still exposes `DockerScanTool.name`. It SHALL resolve each
matched tool to the category label it covers before the resolved list leaves the resolver, so that
no caller holds a scanner identity to print.

The selection set SHALL be assembled from the fields the schema actually has. `name` and
`categories` are optional: when the gateway rejects one with a field-level validation error, that
field SHALL be dropped from the selection and the query retried. Selecting a field the schema has
dropped fails the whole query, which would break an id-based `scan-tools` value exactly as hard as
a name-based one, and `scan-tools` is pinned in consumers' own workflow files. Any GraphQL error
that is not a rejected optional field SHALL still abort the run.

#### Scenario: Tools resolved by name and by id
- **WHEN** `scan-tools` names one tool by its stored name and a second by its id
- **THEN** both entries resolve to tool ids and the action reports the number of scan tools
  selected
- **AND** each resolved tool is listed under its category label alongside the id it was resolved
  to

#### Scenario: The gateway has no categories field
- **WHEN** the gateway answers a selection containing `categories` with a validation error naming
  that field
- **THEN** the query is retried without it and the run proceeds
- **AND** every resolved tool is labelled `Uncategorised`

#### Scenario: The gateway has no name field
- **WHEN** the gateway answers a selection containing `name` with a validation error naming that
  field, and `scan-tools` holds a tool id
- **THEN** the query is retried without it, the id resolves, and the scan is started
- **AND** the run does not report a GraphQL failure or an availability failure

#### Scenario: A name is requested from a gateway that resolves only ids
- **WHEN** an entry is not a tool id and the gateway no longer exposes `name`
- **THEN** the action fails with a message stating that the entry is not a scan tool id and that
  this gateway no longer resolves scan tools by name, and pointing at the Vulnara application for
  the id
- **AND** the message does not claim the tool is unavailable to the tenant

#### Scenario: Unknown tool requested
- **WHEN** an entry in `scan-tools` matches no `dockerScanTools` id, and no name where names still
  resolve
- **THEN** the action fails with a message naming the rejected entry and the tenant, and pointing
  at the Vulnara application for the scanners the tenant may run
- **AND** the message names no scanner the platform offers

#### Scenario: No usable tool entries
- **WHEN** `scan-tools` contains only separators and whitespace
- **THEN** the action fails with `no scan tools provided`

### Requirement: Start one scan per tool
The system SHALL call the `startRepositoryScan` mutation once per resolved tool with the
resolved repository id, the tool id, the branch, and boolean `createIssue` and
`autoRemediate` flags derived from the `create-issue` and `auto-remediate` inputs, including
`gitTokenId` only when `git-token-id` is non-empty. It SHALL collect the returned scan
result ids.

#### Scenario: Scans started
- **WHEN** two tools are resolved
- **THEN** two `startRepositoryScan` mutations are issued and each returned scan result id is
  logged as `started '<category label>' -> scan <id>`

#### Scenario: git-token-id omitted when unset
- **WHEN** `git-token-id` is empty
- **THEN** the mutation input contains no `gitTokenId` field

#### Scenario: Mutation returns no scan result id
- **WHEN** `startRepositoryScan` returns an empty scan result id for a tool
- **THEN** the action fails with `scan did not return a scan result id` naming that scan's
  category label

### Requirement: Wait for scans to finish
The system SHALL poll the `scanResult` query for each started scan every `poll-interval`
seconds until its status is terminal, treating a missing status as `PENDING`, and SHALL log
each status transition with the elapsed time. Each scan is waited on with its own deadline of
`wait-timeout` seconds.

#### Scenario: Scan completes successfully
- **WHEN** a scan reaches status `SUCCESS`
- **THEN** waiting stops for that scan and its elapsed duration is recorded and logged as
  `<category label> completed in <n>s`

#### Scenario: Scan ends in a failure state
- **WHEN** a scan reaches status `FAILED` or `CANCELLED`
- **THEN** the action fails with `scan for '<category label>' ended as <status> (id <scan id>)`

#### Scenario: Scan exceeds the wait timeout
- **WHEN** a scan has not reached a terminal status within `wait-timeout` seconds
- **THEN** the action fails with a timeout message naming the timeout, the last observed
  status and the scan result id

### Requirement: Never identify a scanner to the caller
The action SHALL NOT write anything that identifies a scanner to the console log, to a GitHub
annotation, to the job summary or to an action output: not the stored `dockerScanTools` name, not
a codename or product name derived from it, and not an enumeration of the catalogue. A workflow
log is world-readable on a public repository, and what ran a scan is not a customer-facing fact.

A scan SHALL be labelled by the category it covers. The labels are fixed: `sast` is
`Code analysis`, `sca` is `Dependencies`, `secrets` is `Secrets`, `pii` is `Personal data`.

A scanner serves one or more categories, so a label MAY be a set. It SHALL be joined and
deduplicated, because two categories rendering to the same label would otherwise count the
scanners behind them.

Where no category can be resolved, the label SHALL be `Uncategorised`. That value is display
only: it is never sent to the platform, never filtered on, and is not a category the platform
knows about.

A failure to resolve a requested tool SHALL NOT enumerate the tools that do resolve. The caller
needs to know that what they asked for was rejected, not what else exists.

#### Scenario: A scan is named in the log or the summary
- **WHEN** any line of the console log, the job summary or an annotation refers to a scan
- **THEN** it names the category the scan covers
- **AND** no scanner name, codename or product name appears in that line

#### Scenario: A scanner serving two categories
- **WHEN** a resolved tool records both `sca` and `secrets`
- **THEN** the scan is labelled `Dependencies, Secrets`
- **AND** a tool recording the same category twice is labelled once, so the label does not
  disclose how many scanners ran

#### Scenario: A scanner whose categories cannot be resolved
- **WHEN** a resolved tool records no category, or the gateway exposes no categories at all
- **THEN** the scan is labelled `Uncategorised`
- **AND** the tool's stored name appears in no log line, annotation, summary row or output

