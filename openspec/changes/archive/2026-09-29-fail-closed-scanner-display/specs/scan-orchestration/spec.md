## ADDED Requirements

### Requirement: Never print a scanner's stored name
The action SHALL NOT write a scanner's stored `dockerScanTools` name to the console log, to
a GitHub annotation, to the job summary or to an action output. The stored name is how the
platform runs a scan, not what the scan is called, and a CI log is world-readable on a public
repository.

Resolution SHALL go through a single mapping, so the mapping and its fallback are decided in
one place rather than at each point a scanner is mentioned. The fallback SHALL NOT be the
stored name: falling back to it is how a newly added scanner leaks its name on the first run
after it is added, which is exactly when nobody is looking. An unmapped scanner SHALL be
reported under a fixed placeholder, which is visibly wrong and gets fixed, rather than under a
name nobody chose.

A failure to resolve a requested tool SHALL NOT enumerate the tools that do resolve. The
caller needs to know that what they asked for was rejected, not what else exists.

#### Scenario: A scanner is named in the log or the summary
- **WHEN** any line of the console log, the job summary or an annotation refers to a scanner
- **THEN** it uses the display name resolved through the shared mapping, never the stored name

#### Scenario: A scanner the mapping does not cover
- **WHEN** a resolved tool's stored name has no entry in the mapping
- **THEN** it is reported as `Unknown scanner`
- **AND** its stored name appears in no log line, annotation, summary row or output

## MODIFIED Requirements

### Requirement: Resolve the requested scan tools
The system SHALL split the `scan-tools` input on commas, trim surrounding whitespace from
each entry, and match each entry against the `dockerScanTools` list by exact id or
case-insensitive name. It SHALL resolve each matched tool to its display name before the
resolved list leaves the resolver, so that no caller holds a stored name to print.

#### Scenario: Tools resolved by name and by id
- **WHEN** `scan-tools` names one tool by its stored name and a second by its id
- **THEN** both entries resolve to tool ids and the action reports the number of scan tools
  selected
- **AND** each resolved tool is listed under its display name alongside the id it was
  resolved to

#### Scenario: Unknown tool requested
- **WHEN** an entry in `scan-tools` matches no `dockerScanTools` id or name
- **THEN** the action fails with a message naming the rejected entry and the tenant, and
  pointing at the Vulnara application for the scanners the tenant may run
- **AND** the message names no scanner the platform offers

#### Scenario: No usable tool entries
- **WHEN** `scan-tools` contains only separators and whitespace
- **THEN** the action fails with `no scan tools provided`
