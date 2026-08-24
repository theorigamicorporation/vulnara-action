## MODIFIED Requirements

### Requirement: Wait for scans to finish
The system SHALL poll the `scanResult` query for every started scan every `poll-interval`
seconds until each scan's status is terminal, treating a missing status as `PENDING`, and SHALL
log each status transition with the elapsed time. All scans SHALL share a single deadline of
`wait-timeout` seconds measured from the moment the first scan was started.

#### Scenario: Scan completes successfully
- **WHEN** a scan reaches status `SUCCESS`
- **THEN** polling stops for that scan and its elapsed duration is recorded and logged as
  `<display name> completed in <n>s`
- **AND** the remaining scans continue to be polled

#### Scenario: Scan ends in a failure state
- **WHEN** any scan reaches status `FAILED` or `CANCELLED`
- **THEN** the action fails with `scan for '<display name>' ended as <status> (id <scan id>)`
  without waiting for the other scans to finish

#### Scenario: Scans exceed the wait timeout
- **WHEN** at least one scan has not reached a terminal status within `wait-timeout` seconds of
  the first scan being started
- **THEN** the action fails with a timeout message naming the timeout and, for every scan still
  outstanding, its display name, last observed status and scan result id
