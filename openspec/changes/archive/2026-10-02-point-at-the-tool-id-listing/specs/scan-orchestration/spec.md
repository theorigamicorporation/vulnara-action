## MODIFIED Requirements

### Requirement: Resolve the requested scan tools by id
The system SHALL read the `dockerScanTools` catalogue for the tenant and resolve every entry in
`scan-tools` to a tool id, failing the run with a message naming the rejected entry when an entry
does not resolve. It SHALL map each matched tool to the category label it covers before the resolved
list leaves the resolver, so that no caller holds a scanner identity to print.

`scan-tools` SHALL be resolved by id only. The system SHALL reject a non-id entry before the
catalogue is fetched, with a message that names the entry, states that this gateway does not
resolve scanners by name, states that a category label belongs to a category scan rather than to
`scan-tools`, and points at where the ids are listed. It SHALL NOT report a non-id entry as
unavailable to the tenant, which sends the caller to look for a scanner that is present.

Where a failure points the caller at the ids, it SHALL name vulnara-cli's `docker_scan_tools`
command and the `dockerScanTools { id categories }` query. The Vulnara application has no screen
listing scanner ids, so a message sending the caller there sends them nowhere.

The selection set SHALL NOT include `name`. The gateway has removed `DockerScanTool.name`, so
requesting it would fail the whole query before any id was matched, and nothing in this action would
print the value if it came back. `categories` SHALL remain optional: when the gateway rejects it with
a field-level validation error, the field SHALL be dropped from the selection and the query retried,
because `gateway-url` is an input and a gateway predating that field is a real deployment, and a
failed query would break an id pinned in a consumer's own workflow file. Any GraphQL error that is
not a rejected optional field SHALL still abort the run.

#### Scenario: Tools resolved by id
- **WHEN** `scan-tools` names two tools by their ids
- **THEN** both entries resolve and the action reports the number of scan tools selected
- **AND** each resolved tool is listed under its category label alongside its id

#### Scenario: The catalogue query requests no scanner name
- **WHEN** the action reads the `dockerScanTools` catalogue
- **THEN** the request body selects no `name`, and one request is enough

#### Scenario: The gateway has no categories field
- **WHEN** the gateway answers a selection containing `categories` with a validation error naming
  that field
- **THEN** the query is retried without it and the run proceeds
- **AND** every resolved tool is labelled `Uncategorised`

#### Scenario: A pinned tool id resolves against the gateway that removed the name
- **WHEN** `scan-tools` holds a tool id and the gateway no longer exposes `name`
- **THEN** the id resolves in one request and the scan is started
- **AND** the run reports neither a GraphQL failure nor an availability failure

#### Scenario: A name is requested
- **WHEN** an entry in `scan-tools` is a scanner's stored name rather than an id
- **THEN** the action fails with a message stating that the entry is not a scan tool id and that
  this gateway does not resolve scanners by name, and pointing at `vulnara docker_scan_tools` and the
  `dockerScanTools` query for the id
- **AND** the message does not claim the tool is unavailable to the tenant
- **AND** no catalogue request is sent, because the entry's shape is knowable without the gateway

#### Scenario: A category label is requested
- **WHEN** an entry in `scan-tools` is a category label rather than an id
- **THEN** the action fails with a message stating that a category label belongs to a category scan
  rather than to `scan-tools`
- **AND** the message does not claim the tool is unavailable to the tenant

#### Scenario: Unknown tool requested
- **WHEN** an entry in `scan-tools` is a well-formed id that matches no `dockerScanTools` id
- **THEN** the action fails with a message naming the rejected entry and the tenant, and pointing
  at `vulnara docker_scan_tools` and the `dockerScanTools` query for the ids the tenant may run
- **AND** the message names no scanner the platform offers

#### Scenario: No usable tool entries
- **WHEN** `scan-tools` contains only separators and whitespace
- **THEN** the action fails with `no scan tools provided`

