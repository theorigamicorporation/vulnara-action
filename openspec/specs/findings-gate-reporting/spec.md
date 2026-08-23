# Findings Gate and Reporting

## Purpose
Covers what happens once all scans have completed: collecting the findings for each scan
result, aggregating them by severity, deciding whether the build passes the `fail-on` gate,
publishing the action outputs, and rendering the GitHub job summary with links back into the
Vulnara platform and to the offending lines of code. This is the part of the action that CI
users see and that determines whether the job succeeds or fails.

## Requirements

### Requirement: Collect findings per scan
The system SHALL query `scanFindings` filtered by `scanResultId` for each completed scan and
read the `id`, `severity`, `file`, `line`, `confidence` and `commitScan.commitHash` of every
item. Findings are counted per scan and totalled per severity across all scans, with severity
compared case-insensitively.

#### Scenario: Findings aggregated across scans
- **WHEN** two scans return findings
- **THEN** the action reports per-severity totals for `Critical`, `High`, `Medium` and `Low`,
  a combined `Total`, and a per-scan finding count

#### Scenario: Scan with no findings
- **WHEN** a scan returns an empty `scanFindings` list
- **THEN** its finding count is `0` and it contributes nothing to the severity totals

#### Scenario: Unrecognised severity value
- **WHEN** a finding carries a severity outside `CRITICAL`, `HIGH`, `MEDIUM` and `LOW`
- **THEN** it is ranked `0` and excluded from the four severity counters

### Requirement: Gate the build on the highest severity
The system SHALL rank severities `CRITICAL`=4, `HIGH`=3, `MEDIUM`=2, `LOW`=1 and map the
`fail-on` input to a threshold rank (`none`=99, `low`=1, `medium`=2, `high`=3,
`critical`=4). The build SHALL fail when the highest observed finding rank is greater than or
equal to the threshold, and pass otherwise.

#### Scenario: Findings meet the threshold
- **WHEN** `fail-on` is `high` and the highest finding severity is `CRITICAL`
- **THEN** the action emits `::error::scan gate failed: highest severity 'Critical'
  meets/exceeds fail-on 'high'` and exits non-zero

#### Scenario: Findings below the threshold
- **WHEN** `fail-on` is `high` and the highest finding severity is `MEDIUM`
- **THEN** the action logs that the scan gate passed and exits zero

#### Scenario: Gate disabled
- **WHEN** `fail-on` is `none`
- **THEN** the job passes regardless of the findings, because no severity rank reaches the
  threshold of 99

#### Scenario: No findings at all
- **WHEN** no scan returns any finding
- **THEN** the highest severity is reported as `none` and the gate passes

### Requirement: Publish action outputs
The system SHALL append `scan-result-ids`, `highest-severity` and `passed` to the file named
by the `GITHUB_OUTPUT` environment variable when it is set. `scan-result-ids` is the
space-separated list of started scan result ids, `highest-severity` is the lowercased highest
severity or `none`, and `passed` is `true` or `false`.

#### Scenario: Outputs written for a failing gate
- **WHEN** the gate fails with a critical finding and `GITHUB_OUTPUT` is set
- **THEN** the file receives `highest-severity=critical` and `passed=false` before the job
  exits non-zero, so downstream steps can read the outputs

#### Scenario: GITHUB_OUTPUT unavailable
- **WHEN** `GITHUB_OUTPUT` is not set in the environment
- **THEN** the action skips writing outputs and still completes its gate decision

### Requirement: Render the job summary
The system SHALL append a Markdown summary to the file named by `GITHUB_STEP_SUMMARY` when it
is set, containing a pass/fail heading, a table of repository, provider, visibility, branch,
languages, gate setting, highest severity and total duration, a severity count table, and a
per-scan table with the tool display name, duration, finding count and a link to
`<app-url>/repository-scans/<scan result id>`.

#### Scenario: Summary written after a scan run
- **WHEN** the scans complete and `GITHUB_STEP_SUMMARY` is set
- **THEN** the summary starts with `## ✅ Vulnara scan: Passed` or `## ❌ Vulnara scan: Failed`
- **AND** the repository cell links to the repository browsing URL when one was resolved,
  and is plain code text otherwise

#### Scenario: Summary unavailable
- **WHEN** `GITHUB_STEP_SUMMARY` is not set
- **THEN** no summary is rendered and the run otherwise behaves identically

### Requirement: Link findings to source lines
The system SHALL include a detailed findings table when the total finding count is greater
than zero, listing severity, location, tool and confidence for findings that have a `file`,
sorted by descending severity rank and capped at 50 rows. Each location SHALL link to the
file at the scanned commit hash using the `/-/blob/` path form for `gitlab` providers and
`/blob/` otherwise, with a `#L<line>` fragment when a line is known.

#### Scenario: Located finding with a commit hash
- **WHEN** a finding has a `file`, a `line` and a `commitScan.commitHash`, and the repository
  URL was resolved
- **THEN** the location cell is a Markdown link to `<repo url>/blob/<commit>/<file>#L<line>`

#### Scenario: Finding without commit or repository URL
- **WHEN** the repository URL is empty or the finding has no commit hash
- **THEN** the location cell is the plain `file:line` text with no link

#### Scenario: Findings without a file are omitted
- **WHEN** a finding has an empty `file`
- **THEN** it is excluded from the detailed table while still counting towards the severity
  totals and the gate

#### Scenario: More than fifty located findings
- **WHEN** more than 50 findings have a file
- **THEN** only the 50 highest-severity rows are rendered
- **AND** a note states how many located findings exist in total and points to the scans
