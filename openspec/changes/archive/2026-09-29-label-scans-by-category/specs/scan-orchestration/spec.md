## REMOVED Requirements

### Requirement: Never print a scanner's stored name

**Reason**: it forbade the stored name but mandated a mapping from it to a product name, and that
mapping is what put `Ripley`, `Bishop`, `Hicks` and `Ash` into every run's log and job summary. A
codename is a scanner identity, and no scanner identity reaches a customer surface. Replaced by
`Never identify a scanner to the caller`, which fixes the label on the category instead.

## ADDED Requirements

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

## MODIFIED Requirements

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
